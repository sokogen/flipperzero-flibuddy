import Foundation

/// The host's view of the `hello` handshake (PROTOCOL.md, Session).
public enum LinkState: Equatable, Sendable {
    case disconnected
    /// Our `hello` is out; waiting for the Flipper's.
    case waitingForHello
    /// The port is open but no Flipper `hello` came within the timeout.
    case noAnswer
    case connected(Hello)
}

public enum SessionEvent: Equatable, Sendable {
    case state(LinkState)
    /// Any message other than `hello`, in arrival order.
    case message(Message)
}

public enum TransportSessionError: Error, Equatable, Sendable {
    case alreadyRunning
}

/// Runs one transport connection: says `hello`, tracks the Flipper's answer and
/// relays everything else as `events`.
///
/// A Flipper `hello` within `helloTimeout` of our last `hello` answers it; any
/// other Flipper `hello` (late, or a repeat) is answered with ours. This mirrors
/// the Flipper's `host_link` so the two never ping-pong.
public actor TransportSession {
    public static let defaultHelloTimeout: Duration = .seconds(2)

    /// State changes and relayed messages, for a single consumer, for the session's lifetime.
    public nonisolated let events: AsyncStream<SessionEvent>
    public private(set) var state: LinkState = .disconnected

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let transport: any Transport
    private let hello: Hello
    private let helloTimeout: Duration
    private var running = false
    private var helloSentAt: ContinuousClock.Instant?
    private var timeoutTask: Task<Void, Never>?

    public init(transport: any Transport, hello: Hello, helloTimeout: Duration = defaultHelloTimeout) {
        self.transport = transport
        self.hello = hello
        self.helloTimeout = helloTimeout
        (events, continuation) = AsyncStream<SessionEvent>.makeStream()
    }

    deinit {
        timeoutTask?.cancel()
        continuation.finish()
    }

    /// Connects, says `hello` and relays messages until the transport drops.
    /// Call again to reconnect.
    public func run() async throws {
        guard !running else { throw TransportSessionError.alreadyRunning }
        running = true
        defer { running = false }

        try await transport.connect()
        let messages = transport.messages
        do {
            try sayHello()
        } catch {
            transport.disconnect()
            throw error
        }
        setState(.waitingForHello)
        armTimeout()

        for await message in messages {
            receive(message)
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        helloSentAt = nil
        setState(.disconnected)
    }

    public func send(_ message: Message) throws {
        try transport.send(message)
    }

    /// Closes the transport; `run()` returns once the link is down.
    public func disconnect() {
        transport.disconnect()
    }

    private func receive(_ message: Message) {
        guard case .hello(let flipper) = message else {
            continuation.yield(.message(message))
            return
        }
        Log.info(.link, "hello received: \(flipper.logFields)")
        let answersOurs = helloSentAt.map { ContinuousClock.now - $0 < helloTimeout } ?? false
        if !answersOurs { try? sayHello() }
        timeoutTask?.cancel()
        timeoutTask = nil
        setState(.connected(flipper))
    }

    private func sayHello() throws {
        try transport.send(.hello(hello))
        helloSentAt = .now
        Log.info(.link, "hello sent: \(hello.logFields)")
    }

    private func armTimeout() {
        timeoutTask = Task { [helloTimeout] in
            try? await Task.sleep(for: helloTimeout)
            guard !Task.isCancelled else { return }
            helloTimedOut()
        }
    }

    private func helloTimedOut() {
        guard state == .waitingForHello else { return }
        Log.notice(.link, "hello timeout: after=\(helloTimeout.logDescription)")
        setState(.noAnswer)
    }

    private func setState(_ new: LinkState) {
        guard new != state else { return }
        state = new
        continuation.yield(.state(new))
    }
}

extension Hello {
    /// `app=… fw=… os=…`, leaving out the fields not sent.
    var logFields: String {
        [("app", app), ("fw", fw), ("os", os)].compactMap { name, value in value.map { "\(name)=\($0)" } }
            .joined(separator: " ")
    }
}
