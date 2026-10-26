#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// `BLECentral` on CoreBluetooth, for macOS, iOS and watchOS. All CoreBluetooth
/// state lives on one serial queue. Checked on hardware, not unit-tested.
///
/// Creating it asks for Bluetooth permission, so the app should do that only
/// when Bluetooth is the chosen transport (`shared` is created lazily).
public final class CoreBluetoothCentral: NSObject, BLECentral, @unchecked Sendable {
    public static let shared = CoreBluetoothCentral()

    private let queue = DispatchQueue(label: "SpoolBuddy.CoreBluetoothCentral")
    private var manager: CBCentralManager!
    // Queue-confined state.
    private var stateWaiters: [BLEPromise<BLEPowerState>] = []
    private var scanners: [UUID: (service: CBUUID, continuation: AsyncStream<DiscoveredPeripheral>.Continuation)] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pendingConnects: [UUID: BLEPromise<any BLEPeripheralLink>] = [:]
    private var links: [UUID: CoreBluetoothPeripheralLink] = [:]

    override public init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
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
            guard let peripheral = manager.retrievePeripherals(withIdentifiers: [id]).first else { return false }
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
            guard manager.state == .poweredOn else { return promise.resolve(.failure(TransportError.bluetoothOff)) }
            guard let peripheral = peripherals[id] else {
                return promise.resolve(.failure(TransportError.peripheralNotFound))
            }
            pendingConnects[id]?.resolve(.failure(CancellationError()))
            pendingConnects[id] = promise
            manager.connect(peripheral)
        }
        return try await promise.value()
    }

    public func cancelConnection(_ id: UUID) {
        queue.async { [self] in
            pendingConnects.removeValue(forKey: id)?.resolve(.failure(CancellationError()))
            if let peripheral = peripherals[id] { manager.cancelPeripheralConnection(peripheral) }
        }
    }

    private func updateScan() {
        guard manager.state == .poweredOn else { return }
        let services = Set(scanners.values.map(\.service))
        if services.isEmpty {
            if manager.isScanning { manager.stopScan() }
        } else {
            // Restarting reports peripherals already seen to a new scanner.
            manager.scanForPeripherals(withServices: Array(services))
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
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let state = Self.powerState(central.state) else { return }
        for waiter in stateWaiters { waiter.resolve(.success(state)) }
        stateWaiters.removeAll()
        if state == .poweredOn {
            updateScan()
            return
        }
        // Peripherals are invalid now and no disconnect callback follows.
        for promise in pendingConnects.values { promise.resolve(.failure(TransportError.bluetoothOff)) }
        pendingConnects.removeAll()
        for link in links.values { link.connectionLost() }
        links.removeAll()
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Flipper"
        let found = DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        for scanner in scanners.values where advertised?.contains(scanner.service) ?? true {
            scanner.continuation.yield(found)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let link = CoreBluetoothPeripheralLink(peripheral: peripheral, queue: queue)
        links[peripheral.identifier] = link
        guard let promise = pendingConnects.removeValue(forKey: peripheral.identifier) else {
            // Nobody waits any more (cancelled): let it go.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        promise.resolve(.success(link))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pendingConnects.removeValue(forKey: peripheral.identifier)?.resolve(.failure(TransportError.notConnected))
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        pendingConnects.removeValue(forKey: peripheral.identifier)?.resolve(.failure(TransportError.notConnected))
        links.removeValue(forKey: peripheral.identifier)?.connectionLost()
    }
}

/// `BLEPeripheralLink` on a connected `CBPeripheral`; runs on the central's queue.
final class CoreBluetoothPeripheralLink: NSObject, BLEPeripheralLink, @unchecked Sendable {
    let peripheral: CBPeripheral
    let identifier: UUID
    private let queue: DispatchQueue
    // Queue-confined state.
    private var events: (@Sendable (BLELinkEvent) -> Void)?
    private var opening: BLEPromise<Void>?
    private var uuids: (service: CBUUID, rx: CBUUID, tx: CBUUID)?
    private var rx: CBCharacteristic?
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
            return failOpening(.serviceNotFound)
        }
        peripheral.discoverCharacteristics([uuids.rx, uuids.tx], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let uuids,
            let rx = service.characteristics?.first(where: { $0.uuid == uuids.rx }),
            let tx = service.characteristics?.first(where: { $0.uuid == uuids.tx })
        else { return failOpening(.serviceNotFound) }
        self.rx = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == uuids?.tx else { return }
        guard error == nil, characteristic.isNotifying else { return failOpening(.serviceNotFound) }
        writeLength = peripheral.maximumWriteValueLength(for: .withResponse)
        opening?.resolve(.success(()))
        opening = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == uuids?.tx, let value = characteristic.value else { return }
        events?(.notification(value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == uuids?.rx else { return }
        events?(error == nil ? .writeConfirmed : .writeFailed)
    }
}
#endif
