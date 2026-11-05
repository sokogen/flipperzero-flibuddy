#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// The `CBCentralManager` calls the central makes: `SystemCentralManager`,
/// or a fake in tests (a real manager needs Bluetooth permission).
protocol CentralManager: AnyObject {
    var state: CBManagerState { get }
    var isScanning: Bool { get }
    func connect(_ peripheral: any CentralPeripheral)
    func cancelConnection(_ peripheral: any CentralPeripheral)
    /// The peripheral the system still knows under `id`.
    func retrieve(_ id: UUID) -> (any CentralPeripheral)?
    func scan(services: [CBUUID])
    func stopScan()
}

/// A peripheral as the central needs it: a `CBPeripheral`, or a fake.
protocol CentralPeripheral: AnyObject {
    var identifier: UUID { get }
    var state: CBPeripheralState { get }
    /// The link for a connection that just opened.
    func makeLink(queue: DispatchQueue) -> any CentralLink
}

/// A connection the central tells when it is gone.
protocol CentralLink: BLEPeripheralLink {
    /// Called on the central's queue when the connection is gone.
    func connectionLost()
}

extension CBPeripheral: CentralPeripheral {
    func makeLink(queue: DispatchQueue) -> any CentralLink {
        CoreBluetoothPeripheralLink(peripheral: self, queue: queue)
    }
}

/// `CentralManager` on a real `CBCentralManager`.
final class SystemCentralManager: CentralManager {
    private let manager: CBCentralManager

    init(delegate: any CBCentralManagerDelegate, queue: DispatchQueue) {
        #if os(iOS)
        manager = CBCentralManager(
            delegate: delegate, queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: CoreBluetoothCentral.restoreIdentifier]
        )
        #else
        manager = CBCentralManager(delegate: delegate, queue: queue)
        #endif
    }

    var state: CBManagerState { manager.state }
    var isScanning: Bool { manager.isScanning }

    func connect(_ peripheral: any CentralPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        manager.connect(peripheral)
    }

    func cancelConnection(_ peripheral: any CentralPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    func retrieve(_ id: UUID) -> (any CentralPeripheral)? {
        manager.retrievePeripherals(withIdentifiers: [id]).first
    }

    func scan(services: [CBUUID]) {
        manager.scanForPeripherals(withServices: services)
    }

    func stopScan() {
        manager.stopScan()
    }
}

/// `BLECentral` on CoreBluetooth, for macOS, iOS and watchOS. All CoreBluetooth
/// state lives on one serial queue. The connection bookkeeping is tested on
/// a fake `CentralManager`; the CoreBluetooth calls are checked on hardware.
///
/// Creating it asks for Bluetooth permission, so the app should do that only
/// when Bluetooth is the chosen transport (`shared` is created lazily). On a
/// relaunch for Bluetooth the iOS app delegate creates it at launch, so that
/// the restored state is delivered.
public final class CoreBluetoothCentral: NSObject, BLECentral, @unchecked Sendable {
    public static let shared = CoreBluetoothCentral()

    let queue = DispatchQueue(label: "FliBuddy.CoreBluetoothCentral")
    private var manager: (any CentralManager)!
    // Queue-confined state.
    private var stateWaiters: [BLEPromise<BLEPowerState>] = []
    private var scanners: [UUID: (service: CBUUID, continuation: AsyncStream<DiscoveredPeripheral>.Continuation)] = [:]
    private var peripherals: [UUID: any CentralPeripheral] = [:]
    private var pendingConnects: [UUID: BLEPromise<any BLEPeripheralLink>] = [:]
    private var links: [UUID: (link: any CentralLink, peripheral: any CentralPeripheral)] = [:]
    /// Connections and attempts we cancelled whose `didDisconnect` is still to
    /// come (CoreBluetooth sends it for a cancelled pending attempt too).
    /// Every connection to a peripheral has its identifier, so a connect
    /// asked for meanwhile waits for that callback instead of being hit by it
    /// or by a late `didConnect` of the cancelled attempt.
    private var closing: Set<UUID> = []

    /// iOS relaunches the app for a Bluetooth event after it terminated the
    /// app in the background, and hands back the peripherals under this key.
    public static let restoreIdentifier = "com.sokolachko.flibuddy.central"

    /// Whether the launch options' `bluetoothCentrals` name our central:
    /// iOS relaunched the app for a Bluetooth event.
    public static func restores(_ centrals: [String]?) -> Bool {
        centrals?.contains(restoreIdentifier) == true
    }

    override public convenience init() {
        self.init { central, queue in SystemCentralManager(delegate: central, queue: queue) }
    }

    /// A central on the manager `makeManager` makes, with this central as
    /// its delegate, on its queue.
    init(makeManager: (CoreBluetoothCentral, DispatchQueue) -> any CentralManager) {
        super.init()
        manager = makeManager(self, queue)
    }

    /// Runs `body` on the central's queue (tests deliver callbacks this way).
    func onQueue(_ body: () -> Void) {
        queue.sync(execute: body)
    }

    public func powerState() async -> BLEPowerState {
        let promise = BLEPromise<BLEPowerState>()
        queue.async { [self] in
            if let state = Self.powerState(manager.state) {
                promise.resolve(.success(state))
            } else {
                stateWaiters.append(promise)
            }
        }
        // Cancellation reads as "off"; the caller stops anyway.
        return (try? await promise.value()) ?? .poweredOff
    }

    public func knowsPeripheral(_ id: UUID) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard let peripheral = manager.retrieve(id) else { return false }
            peripherals[id] = peripheral
            return true
        }
    }

    public func scan(service: UUID) -> AsyncStream<DiscoveredPeripheral> {
        let (stream, continuation) = AsyncStream<DiscoveredPeripheral>.makeStream()
        let token = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            queue.async {
                self.scanners[token] = nil
                self.updateScan()
            }
        }
        queue.async { [self] in
            scanners[token] = (CBUUID(nsuuid: service), continuation)
            updateScan()
        }
        return stream
    }

    public func connect(_ id: UUID) async throws -> any BLEPeripheralLink {
        let promise = BLEPromise<any BLEPeripheralLink>()
        queue.async { [self] in
            guard manager.state == .poweredOn else {
                promise.resolve(.failure(TransportError.bluetoothOff))
                return
            }
            guard let peripheral = peripherals[id] else {
                promise.resolve(.failure(TransportError.peripheralNotFound))
                return
            }
            pendingConnects[id]?.resolve(.failure(CancellationError()))
            pendingConnects[id] = promise
            // A cancelled attempt that never connected may end without any
            // callback; once the peripheral reads disconnected, nothing of
            // it is left to wait for.
            if closing.contains(id), links[id] == nil, peripheral.state == .disconnected {
                closing.remove(id)
                Log.notice(.link, "bluetooth central closing cleared: peripheral=\(id.uuidString) (no disconnect came)")
            }
            if !closing.contains(id) { manager.connect(peripheral) }
        }
        return try await withTaskCancellationHandler {
            try await promise.value()
        } onCancel: {
            queue.async { [self] in abandon(promise, id) }
        }
    }

    public func disconnect(_ link: any BLEPeripheralLink) {
        queue.async { [self] in
            guard let current = links[link.identifier], current.link === link else { return }
            close(current.peripheral)
        }
    }

    /// Gives up a connection attempt nobody waits for any more, unless a
    /// newer attempt took its place.
    private func abandon(_ promise: BLEPromise<any BLEPeripheralLink>, _ id: UUID) {
        guard pendingConnects[id] === promise else { return }
        pendingConnects[id] = nil
        // While closing, the connect was not started yet.
        guard !closing.contains(id), let peripheral = peripherals[id] else { return }
        close(peripheral)
    }

    /// Cancels a connection or a pending attempt; `didDisconnect` follows.
    private func close(_ peripheral: any CentralPeripheral) {
        closing.insert(peripheral.identifier)
        manager.cancelConnection(peripheral)
    }

    /// Whether `peripheral` was closing: then what we cancelled is gone, and
    /// a connect asked for since goes ahead.
    private func closed(_ peripheral: any CentralPeripheral) -> Bool {
        guard closing.remove(peripheral.identifier) != nil else { return false }
        if pendingConnects[peripheral.identifier] != nil { manager.connect(peripheral) }
        return true
    }

    private func updateScan() {
        guard manager.state == .poweredOn else { return }
        let services = Set(scanners.values.map(\.service))
        if services.isEmpty {
            guard manager.isScanning else { return }
            Log.info(.link, "bluetooth central scan stop")
            manager.stopScan()
        } else {
            // Restarting reports peripherals already seen to a new scanner.
            Log.info(.link, "bluetooth central scan start: scanners=\(scanners.count)")
            manager.scan(services: Array(services))
        }
    }

    private static func powerState(_ state: CBManagerState) -> BLEPowerState? {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown, .resetting: nil
        @unknown default: .unsupported
        }
    }
}

extension CoreBluetoothCentral: CBCentralManagerDelegate {
    /// After a relaunch the restored peripherals are known again; the link
    /// connects to its saved Flipper as on any start, and CoreBluetooth
    /// answers a connect to one that is still connected at once.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored { peripherals[peripheral.identifier] = peripheral }
        Log.notice(.link, "bluetooth central restored: peripherals=\(restored.count)")
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleState(central.state)
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let name = FliBuddyGATT.displayName(
            peripheralName: peripheral.name,
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        let found = DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        Log.info(.link, "bluetooth central discovered: peripheral=\(found.id.uuidString) name=\(name) rssi=\(found.rssi)")
        for scanner in scanners.values where advertised?.contains(scanner.service) ?? true {
            scanner.continuation.yield(found)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        handleConnected(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.error(.link, "bluetooth central connect failed: peripheral=\(peripheral.identifier.uuidString) error=\(describe(error))")
        handleFailedToConnect(peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        Log.info(.link, "bluetooth central disconnected: peripheral=\(peripheral.identifier.uuidString) error=\(describe(error))")
        handleDisconnected(peripheral)
    }
}

/// The central's callbacks, on its queue.
extension CoreBluetoothCentral {
    /// A known radio state answers the waiters. Off, unauthorized or
    /// unsupported, and also resetting or unknown (the radio restarts, the
    /// system's Bluetooth daemon was restarted), drop every connection and
    /// attempt: the peripherals are invalid then and no disconnect callback
    /// follows. While resetting or unknown the waiters keep waiting.
    func handleState(_ managerState: CBManagerState) {
        guard let state = Self.powerState(managerState) else {
            Log.notice(.link, "bluetooth central power: \(managerState == .resetting ? "resetting" : "unknown")")
            dropAll(TransportError.notConnected)
            return
        }
        Log.info(.link, "bluetooth central power: \(state)")
        for waiter in stateWaiters { waiter.resolve(.success(state)) }
        stateWaiters.removeAll()
        if state == .poweredOn {
            updateScan()
            return
        }
        dropAll(TransportError.bluetoothOff)
    }

    private func dropAll(_ error: TransportError) {
        for promise in pendingConnects.values { promise.resolve(.failure(error)) }
        pendingConnects.removeAll()
        for entry in links.values { entry.link.connectionLost() }
        links.removeAll()
        closing.removeAll()
    }

    func handleConnected(_ peripheral: any CentralPeripheral) {
        // An attempt cancelled after it connected: its `didDisconnect` follows
        // and starts the attempt that waits, which this one must not answer.
        guard !closing.contains(peripheral.identifier) else { return }
        Log.info(.link, "bluetooth central connected: peripheral=\(peripheral.identifier.uuidString)")
        let link = peripheral.makeLink(queue: queue)
        links[peripheral.identifier] = (link, peripheral)
        // A waiter cancelled just now may still be pending here.
        guard let promise = pendingConnects.removeValue(forKey: peripheral.identifier),
            promise.resolve(.success(link))
        else {
            // Nobody waits any more (cancelled): let it go.
            close(peripheral)
            return
        }
    }

    func handleFailedToConnect(_ peripheral: any CentralPeripheral) {
        // A cancelled attempt may end this way instead.
        guard !closed(peripheral) else { return }
        pendingConnects.removeValue(forKey: peripheral.identifier)?.resolve(.failure(TransportError.notConnected))
    }

    func handleDisconnected(_ peripheral: any CentralPeripheral) {
        links.removeValue(forKey: peripheral.identifier)?.link.connectionLost()
        guard !closed(peripheral) else { return }
        pendingConnects.removeValue(forKey: peripheral.identifier)?.resolve(.failure(TransportError.notConnected))
    }
}

/// `BLEPeripheralLink` on a connected `CBPeripheral`; runs on the central's queue.
final class CoreBluetoothPeripheralLink: NSObject, CentralLink, @unchecked Sendable {
    let peripheral: CBPeripheral
    let identifier: UUID
    private let queue: DispatchQueue
    // Queue-confined state.
    private var events: (@Sendable (BLELinkEvent) -> Void)?
    private var opening: BLEPromise<Void>?
    private var uuids: (service: CBUUID, rx: CBUUID, tx: CBUUID)?
    private var rx: CBCharacteristic?
    /// The connection dropped; an `open` that comes later fails at once.
    private var lost = false
    /// Written on the queue before `open` returns, read after.
    private var writeLength = BLEChunker.defaultWriteSize

    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        identifier = peripheral.identifier
        self.queue = queue
        super.init()
    }

    var maximumWriteValueLength: Int { writeLength }

    func open(service: UUID, rx: UUID, tx: UUID, events: @escaping @Sendable (BLELinkEvent) -> Void) async throws {
        let promise = BLEPromise<Void>()
        queue.async { [self] in
            // The link may drop between `didConnect` and this block.
            guard !lost, peripheral.state == .connected else {
                promise.resolve(.failure(TransportError.notConnected))
                return
            }
            self.events = events
            opening = promise
            let service = CBUUID(nsuuid: service)
            uuids = (service, CBUUID(nsuuid: rx), CBUUID(nsuuid: tx))
            peripheral.delegate = self
            peripheral.discoverServices([service])
        }
        try await promise.value()
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard let rx else { return }
            peripheral.writeValue(data, for: rx, type: .withResponse)
        }
    }

    /// Called by the central on its queue when the connection is gone.
    func connectionLost() {
        lost = true
        opening?.resolve(.failure(TransportError.notConnected))
        opening = nil
        events?(.disconnected)
        events = nil
    }

    private func failOpening(_ error: TransportError) {
        opening?.resolve(.failure(error))
        opening = nil
    }
}

extension CoreBluetoothPeripheralLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let uuids, let service = peripheral.services?.first(where: { $0.uuid == uuids.service }) else {
            Log.error(.link, "bluetooth service missing: peripheral=\(identifier.uuidString) error=\(describe(error))")
            return failOpening(.serviceNotFound)
        }
        Log.info(.link, "bluetooth service found: peripheral=\(identifier.uuidString)")
        peripheral.discoverCharacteristics([uuids.rx, uuids.tx], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let uuids,
            let rx = service.characteristics?.first(where: { $0.uuid == uuids.rx }),
            let tx = service.characteristics?.first(where: { $0.uuid == uuids.tx })
        else {
            Log.error(.link, "bluetooth characteristics missing: peripheral=\(identifier.uuidString) error=\(describe(error))")
            return failOpening(.serviceNotFound)
        }
        Log.info(.link, "bluetooth characteristics found: peripheral=\(identifier.uuidString)")
        self.rx = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == uuids?.tx else { return }
        guard error == nil, characteristic.isNotifying else {
            Log.error(.link, "bluetooth notify failed: peripheral=\(identifier.uuidString) error=\(describe(error))")
            return failOpening(.serviceNotFound)
        }
        // The without-response length follows the ATT MTU; the with-response
        // one is the 512-byte attribute limit, reached only by long writes.
        writeLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        Log.info(.link, "bluetooth mtu: peripheral=\(identifier.uuidString) mtu=\(writeLength + 3) max_write=\(writeLength)")
        opening?.resolve(.success(()))
        opening = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == uuids?.tx, let value = characteristic.value else { return }
        events?(.notification(value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == uuids?.rx else { return }
        if let error {
            Log.error(.link, "bluetooth write error: peripheral=\(identifier.uuidString) error=\(describe(error))")
        }
        events?(error == nil ? .writeConfirmed : .writeFailed)
    }
}
/// A CoreBluetooth error for the log; `none` when there is none.
private func describe(_ error: (any Error)?) -> String {
    error?.localizedDescription ?? "none"
}
#endif
