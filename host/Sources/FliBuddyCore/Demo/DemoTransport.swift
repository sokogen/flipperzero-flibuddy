import Foundation

/// The demo's Flipper link: opens at once, answers the host's `hello` with
/// the Flipper's, takes every line it is sent and never drops. `onConnect`
/// runs on each `connect()`, outside the lock.
final class DemoTransport: Transport, @unchecked Sendable {
    static let flipperHello = Hello(app: "flibuddy-fap/1.0", fw: "1.5.1")

    private let lock = NSLock()
    private var continuation: AsyncStream<Message>.Continuation?
    private var stream = AsyncStream<Message> { $0.finish() }
    private var sentLines: [Message] = []
    private let onConnect: @Sendable () -> Void

    init(onConnect: @escaping @Sendable () -> Void = {}) {
        self.onConnect = onConnect
    }

    var state: TransportState {
        lock.withLock { continuation == nil ? .closed : .open }
    }

    var messages: AsyncStream<Message> {
        lock.withLock { stream }
    }

    /// What the host sent, in order.
    var sent: [Message] {
        lock.withLock { sentLines }
    }

    func connect() async throws {
        let opened: Bool = lock.withLock {
            guard continuation == nil else { return false }
            let (stream, continuation) = AsyncStream<Message>.makeStream()
            // Buffered until the transport session reads it, after its own hello.
            continuation.yield(.hello(Self.flipperHello))
            self.stream = stream
            self.continuation = continuation
            return true
        }
        if opened { onConnect() }
    }

    func send(_ message: Message) throws {
        try lock.withLock {
            guard continuation != nil else { throw TransportError.notConnected }
            sentLines.append(message)
        }
    }

    func disconnect() {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }
}
