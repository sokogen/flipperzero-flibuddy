import Foundation

/// The radio as the central sees it.
public enum BLEPowerState: Equatable, Sendable {
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
}

/// A Flipper found by a scan, for the settings picker.
public struct DiscoveredPeripheral: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// What a connected peripheral reports once `open` returned.
public enum BLELinkEvent: Equatable, Sendable {
    /// A TX notification.
    case notification(Data)
    /// The RX write in flight was acknowledged.
    case writeConfirmed
    /// The RX write in flight was refused.
    case writeFailed
    /// The connection is gone, including when Bluetooth was switched off.
    /// Nothing follows it.
    case disconnected
}

/// The central role, as `BLETransport` needs it. `CoreBluetoothCentral` is the
/// real one; tests use a fake.
public protocol BLECentral: AnyObject, Sendable {
    /// The radio state, once the system knows it.
    func powerState() async -> BLEPowerState
    /// Whether the system still knows a peripheral seen before, so that it
    /// can be connected without a scan.
    func knowsPeripheral(_ id: UUID) -> Bool
    /// Peripherals advertising `service`, as they are found. Scanning stops
    /// when the consumer stops iterating.
    func scan(service: UUID) -> AsyncStream<DiscoveredPeripheral>
    /// Connects a known or scanned peripheral. Throws `CancellationError` when
    /// the calling task is cancelled.
    func connect(_ id: UUID) async throws -> any BLEPeripheralLink
    /// Drops the connection to `id`, or the attempt to make it.
    func cancelConnection(_ id: UUID)
}

/// One connected peripheral.
public protocol BLEPeripheralLink: AnyObject, Sendable {
    var identifier: UUID { get }
    /// Discovers `service` with its `rx` and `tx` characteristics and turns
    /// on TX notifications; throws `TransportError.serviceNotFound` when the
    /// peripheral lacks them, `CancellationError` when the task is cancelled.
    /// `events` receives everything from the start of the call on, in order,
    /// on any thread: a notification may arrive before `open` returns.
    func open(service: UUID, rx: UUID, tx: UUID, events: @escaping @Sendable (BLELinkEvent) -> Void) async throws
    /// The largest RX write with response; valid once `open` returned.
    var maximumWriteValueLength: Int { get }
    /// Writes RX with response; `writeConfirmed` or `writeFailed` follows.
    func write(_ data: Data)
}

/// A one-shot result handed from a callback queue to an `async` caller.
/// Cancelling the waiting task fails it with `CancellationError`; only the
/// first `resolve` counts.
final class BLEPromise<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    init() {}

    var isResolved: Bool { lock.withLock { result != nil } }

    func resolve(_ result: Result<Value, Error>) {
        let waiting: CheckedContinuation<Value, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Value, Error>? = lock.withLock {
                    if result == nil { self.continuation = continuation }
                    return result
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }
}
