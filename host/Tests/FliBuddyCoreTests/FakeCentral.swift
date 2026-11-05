import Foundation
@testable import FliBuddyCore

/// In-memory `BLECentral`: a scan finds `advertising`, `connect` hands out one
/// `FakePeripheral` per identifier.
final class FakeCentral: BLECentral, @unchecked Sendable {
    private let lock = NSLock()
    private var _power: BLEPowerState = .poweredOn
    private var _known: Set<UUID> = []
    private var _advertising: [DiscoveredPeripheral] = []
    private var _peripherals: [UUID: FakePeripheral] = [:]
    private var _scanCount = 0
    private var _connected: [UUID] = []
    private var _cancelled: [UUID] = []
    private var _disconnectedLinks: [FakePeripheral] = []
    private var scanners: [UUID: AsyncStream<DiscoveredPeripheral>.Continuation] = [:]
    /// `connect` waits until it is cancelled.
    var connectHangs = false
    /// Peripherals created from now on lack the FliBuddy service.
    var withoutService = false
    /// Peripherals created from now on confirm every write by themselves.
    var autoConfirm = false

    var power: BLEPowerState {
        get { lock.withLock { _power } }
        set { lock.withLock { _power = newValue } }
    }

    var known: Set<UUID> {
        get { lock.withLock { _known } }
        set { lock.withLock { _known = newValue } }
    }

    var scanCount: Int { lock.withLock { _scanCount } }
    var connected: [UUID] { lock.withLock { _connected } }
    /// Abandoned connection attempts and dropped connections, in order.
    var cancelled: [UUID] { lock.withLock { _cancelled } }
    /// The connections `disconnect` was asked to drop.
    var disconnectedLinks: [FakePeripheral] { lock.withLock { _disconnectedLinks } }
    var activeScans: Int { lock.withLock { scanners.count } }

    func peripheral(_ id: UUID) -> FakePeripheral {
        lock.withLock {
            if let existing = _peripherals[id] { return existing }
            let created = FakePeripheral(identifier: id, hasService: !withoutService, autoConfirm: autoConfirm)
            _peripherals[id] = created
            return created
        }
    }

    /// Hands out a new `FakePeripheral` for `id` from the next `connect` on,
    /// as CoreBluetooth makes a new link per connection.
    func replacePeripheral(_ id: UUID) -> FakePeripheral {
        lock.withLock {
            let created = FakePeripheral(identifier: id, hasService: !withoutService, autoConfirm: autoConfirm)
            _peripherals[id] = created
            return created
        }
    }

    /// A Flipper starts advertising; running scans see it too.
    func advertise(_ found: DiscoveredPeripheral) {
        let running = lock.withLock {
            _advertising.append(found)
            return Array(scanners.values)
        }
        for scanner in running { scanner.yield(found) }
    }

    /// Bluetooth goes off: connections drop without a disconnect from the peer.
    func powerOff() {
        let links = lock.withLock {
            _power = .poweredOff
            return Array(_peripherals.values)
        }
        for link in links { link.drop() }
    }

    func powerState() async -> BLEPowerState { power }

    func knowsPeripheral(_ id: UUID) -> Bool { known.contains(id) }

    func scan(service: UUID) -> AsyncStream<DiscoveredPeripheral> {
        let (stream, continuation) = AsyncStream<DiscoveredPeripheral>.makeStream()
        let token = UUID()
        let found = lock.withLock {
            _scanCount += 1
            scanners[token] = continuation
            return service == FliBuddyGATT.service ? _advertising : []
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.lock.withLock { self?.scanners.removeValue(forKey: token) }
        }
        for peripheral in found { continuation.yield(peripheral) }
        return stream
    }

    func connect(_ id: UUID) async throws -> any BLEPeripheralLink {
        if connectHangs {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                lock.withLock { _cancelled.append(id) }
                throw error
            }
        }
        lock.withLock { _connected.append(id) }
        let link = peripheral(id)
        link.isConnected = true
        return link
    }

    func disconnect(_ link: any BLEPeripheralLink) {
        let fake = link as? FakePeripheral
        lock.withLock {
            _cancelled.append(link.identifier)
            if let fake { _disconnectedLinks.append(fake) }
        }
        fake?.drop()
    }
}

/// The Flipper's side of one connection: records RX writes, sends TX
/// notifications.
final class FakePeripheral: BLEPeripheralLink, @unchecked Sendable {
    let identifier: UUID
    private let lock = NSLock()
    private let hasService: Bool
    private let autoConfirm: Bool
    private var events: (@Sendable (BLELinkEvent) -> Void)?
    /// The handler `open` got, kept after a drop for `emitLate`.
    private var openedWith: (@Sendable (BLELinkEvent) -> Void)?
    private var _writes: [Data] = []
    private var _isConnected = false
    private var _writeLength = 20
    /// Notified while `open` subscribes, as the FAP sends its `hello` then.
    var onSubscribe: Data?
    /// The connection drops while `open` subscribes.
    var dropsWhileOpening = false
    /// `open` waits until it is cancelled (service discovery that stalls).
    var openHangs = false

    init(identifier: UUID, hasService: Bool, autoConfirm: Bool) {
        self.identifier = identifier
        self.hasService = hasService
        self.autoConfirm = autoConfirm
    }

    var writes: [Data] { lock.withLock { _writes } }

    var isConnected: Bool {
        get { lock.withLock { _isConnected } }
        set { lock.withLock { _isConnected = newValue } }
    }

    var maximumWriteValueLength: Int {
        get { lock.withLock { _writeLength } }
        set { lock.withLock { _writeLength = newValue } }
    }

    func open(service: UUID, rx: UUID, tx: UUID, events: @escaping @Sendable (BLELinkEvent) -> Void) async throws {
        guard hasService, service == FliBuddyGATT.service, rx == FliBuddyGATT.rx, tx == FliBuddyGATT.tx else {
            throw TransportError.serviceNotFound
        }
        if openHangs { try await Task.sleep(for: .seconds(3600)) }
        lock.withLock {
            self.events = events
            openedWith = events
        }
        if let onSubscribe { notify(onSubscribe) }
        if dropsWhileOpening { drop() }
    }

    func write(_ data: Data) {
        lock.withLock { _writes.append(data) }
        if autoConfirm { Task { self.confirmWrite() } }
    }

    func notify(_ data: Data) {
        emit(.notification(data))
    }

    /// Sends `message` as TX notifications of at most `size` bytes.
    func notify(_ message: Message, size: Int = 20) throws {
        var line = try message.encodedLine()[...]
        while !line.isEmpty {
            notify(Data(line.prefix(size)))
            line = line.dropFirst(size)
        }
    }

    func confirmWrite() { emit(.writeConfirmed) }

    func failWrite() { emit(.writeFailed) }

    /// The connection goes away; the link says so once.
    func drop() {
        let events = lock.withLock {
            defer { self.events = nil }
            _isConnected = false
            return self.events
        }
        events?(.disconnected)
    }

    /// An event that arrives after the link dropped, as a late CoreBluetooth
    /// callback would.
    func emitLate(_ event: BLELinkEvent) {
        lock.withLock { openedWith }?(event)
    }

    private func emit(_ event: BLELinkEvent) {
        lock.withLock { events }?(event)
    }
}
