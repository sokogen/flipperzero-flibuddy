import Foundation

/// The Flipper over its SpoolBuddy GATT service: NDJSON lines written to RX,
/// one write in flight at a time, and read from TX notifications.
///
/// `connect()` uses the remembered peripheral when the system still knows it,
/// otherwise scans for the service (for that peripheral, or the first one
/// found), connects, subscribes to TX and only then reports `.open`.
public final class BLETransport: Transport, @unchecked Sendable {
    public static let defaultScanTimeout: Duration = .seconds(10)
    public static let defaultConnectTimeout: Duration = .seconds(10)

    /// The peripheral asked for; `nil` takes the first Flipper found.
    public let requestedPeripheral: UUID?

    private let central: any BLECentral
    private let scanTimeout: Duration
    private let connectTimeout: Duration
    /// Guards everything below.
    private let lock = NSLock()
    /// The connection being opened or open; events of any other link are stale.
    private var link: (any BLEPeripheralLink)?
    private var isOpen = false
    private var chunker = BLEChunker()
    private var continuation: AsyncStream<Message>.Continuation?
    private var stream = AsyncStream<Message> { $0.finish() }

    public init(
        central: any BLECentral, peripheral: UUID?,
        scanTimeout: Duration = defaultScanTimeout, connectTimeout: Duration = defaultConnectTimeout
    ) {
        self.central = central
        requestedPeripheral = peripheral
        self.scanTimeout = scanTimeout
        self.connectTimeout = connectTimeout
    }

    public var state: TransportState {
        lock.withLock { isOpen ? .open : .closed }
    }

    public var messages: AsyncStream<Message> {
        lock.withLock { stream }
    }

    /// The peripheral of the open connection.
    public var connectedPeripheral: UUID? {
        lock.withLock { isOpen ? link?.identifier : nil }
    }

    public func connect() async throws {
        guard state == .closed else { return }
        switch await central.powerState() {
        case .poweredOn: break
        case .poweredOff: throw TransportError.bluetoothOff
        case .unauthorized: throw TransportError.bluetoothUnauthorized
        case .unsupported: throw TransportError.bluetoothUnsupported
        }
        let id = try await findPeripheral()
        do {
            try await Self.withDeadline(connectTimeout, else: .peripheralNotFound) { [self] in
                try await open(try await central.connect(id))
            }
            try Task.checkCancellation()
        } catch {
            drop(where: { $0.identifier == id })
            central.cancelConnection(id)
            throw error
        }
    }

    public func send(_ message: Message) throws {
        let (link, write): ((any BLEPeripheralLink)?, Data?) = try lock.withLock {
            guard isOpen, let link else { throw TransportError.notConnected }
            try chunker.enqueue(message)
            return (link, chunker.nextWrite())
        }
        if let write { link?.write(write) }
    }

    public func disconnect() {
        guard let id = lock.withLock({ link?.identifier }) else { return }
        drop(where: { $0.identifier == id })
        central.cancelConnection(id)
    }

    private func findPeripheral() async throws -> UUID {
        if let requestedPeripheral, central.knowsPeripheral(requestedPeripheral) { return requestedPeripheral }
        let found = central.scan(service: SpoolBuddyGATT.service)
        return try await Self.withDeadline(scanTimeout, else: .peripheralNotFound) { [requestedPeripheral] in
            for await peripheral in found where requestedPeripheral == nil || peripheral.id == requestedPeripheral {
                return peripheral.id
            }
            throw TransportError.peripheralNotFound
        }
    }

    /// Subscribes to TX. The message stream exists before the subscription,
    /// so a `hello` the Flipper sends right away is kept.
    private func open(_ link: any BLEPeripheralLink) async throws {
        let (stream, continuation) = AsyncStream<Message>.makeStream()
        lock.withLock {
            self.link = link
            self.stream = stream
            self.continuation = continuation
            chunker.reset()
        }
        try await link.open(service: SpoolBuddyGATT.service, rx: SpoolBuddyGATT.rx, tx: SpoolBuddyGATT.tx) {
            [weak self, weak link] event in
            guard let self, let link else { return }
            self.handle(event, from: link)
        }
        try lock.withLock {
            guard self.link === link else { throw TransportError.notConnected }
            chunker.writeSize = link.maximumWriteValueLength
            isOpen = true
        }
    }

    private func handle(_ event: BLELinkEvent, from source: any BLEPeripheralLink) {
        switch event {
        case .notification(let data):
            lock.withLock {
                guard link === source else { return }
                for message in chunker.receive(data) { continuation?.yield(message) }
            }
        case .writeConfirmed:
            let write: Data? = lock.withLock {
                guard link === source else { return nil }
                chunker.writeConfirmed()
                return chunker.nextWrite()
            }
            if let write { source.write(write) }
        case .writeFailed:
            // The line is broken mid-way; the Flipper discards the partial
            // line when the link drops.
            guard drop(where: { $0 === source }) else { return }
            central.cancelConnection(source.identifier)
        case .disconnected:
            drop(where: { $0 === source })
        }
    }

    /// Forgets the current connection if `matches` it and finishes its
    /// message stream; returns whether it did.
    @discardableResult
    private func drop(where matches: (any BLEPeripheralLink) -> Bool) -> Bool {
        let (dropped, finished): (Bool, AsyncStream<Message>.Continuation?) = lock.withLock {
            guard let link, matches(link) else { return (false, nil) }
            self.link = nil
            isOpen = false
            chunker.reset()
            defer { continuation = nil }
            return (true, continuation)
        }
        finished?.finish()
        return dropped
    }

    /// Runs `operation`, throwing `error` if it takes longer than `timeout`.
    /// The operation is cancelled then and must return promptly.
    static func withDeadline<T: Sendable>(
        _ timeout: Duration, else error: TransportError, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: timeout)
                throw error
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
