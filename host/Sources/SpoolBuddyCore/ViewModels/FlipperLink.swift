import Foundation
import Observation

/// Keeps the Flipper connected: opens the port (the chosen one or the first
/// Flipper found), runs the `hello` handshake, hands every Flipper message to
/// the session and sends its reply. A dropped or failed link is retried
/// after `retryDelay` until `disconnect()`.
@MainActor
@Observable
public final class FlipperLink {
    public static let noFlipperFound = "No Flipper found"

    public private(set) var state: LinkState = .disconnected
    /// The port in use or being opened.
    public private(set) var port: String?
    /// The port asked for; `nil` uses the first Flipper found.
    public private(set) var requestedPort: String?
    /// Why the link is down, if it is not just closed.
    public private(set) var problem: String?
    public private(set) var isActive = false

    public var statusText: String { Self.statusText(state, problem: problem) }

    private let session: Session
    private let hello: Hello
    private let makeTransport: @Sendable (String) -> any Transport
    private let discoverPorts: @Sendable () -> [String]
    private let retryDelay: Duration
    private var loop: Task<Void, Never>?
    private var transport: (any Transport)?
    /// Bumped by `connect` and `disconnect`; a stale loop changes nothing.
    private var generation = 0

    public init(
        session: Session, hello: Hello,
        makeTransport: @escaping @Sendable (String) -> any Transport = { SerialTransport(path: $0) },
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() },
        retryDelay: Duration = .seconds(2)
    ) {
        self.session = session
        self.hello = hello
        self.makeTransport = makeTransport
        self.discoverPorts = discoverPorts
        self.retryDelay = retryDelay
    }

    /// (Re)starts the link on `port`, or on the first Flipper found.
    public func connect(port: String?) {
        disconnect()
        requestedPort = port
        isActive = true
        let current = generation
        loop = Task { await self.run(requested: port, generation: current) }
    }

    public func disconnect() {
        generation += 1
        loop?.cancel()
        loop = nil
        transport?.disconnect()
        transport = nil
        isActive = false
        state = .disconnected
        port = nil
        problem = nil
    }

    private func run(requested: String?, generation current: Int) async {
        while !Task.isCancelled, current == generation {
            if let path = requested ?? discoverPorts().first {
                await runOnce(path, generation: current)
            } else {
                problem = Self.noFlipperFound
            }
            try? await Task.sleep(for: retryDelay)
        }
    }

    private func runOnce(_ path: String, generation current: Int) async {
        let transport = makeTransport(path)
        let link = TransportSession(transport: transport, hello: hello)
        self.transport = transport
        port = path
        let pump = Task {
            for await event in link.events {
                guard current == self.generation else { return }
                switch event {
                case .state(let state):
                    self.state = state
                    if state != .disconnected { self.problem = nil }
                case .message(let message):
                    if let reply = await self.session.handle(message) {
                        try? await link.send(reply)
                    }
                }
            }
        }
        var failure: String?
        do {
            try await link.run()
        } catch {
            failure = Session.describe(error)
        }
        pump.cancel()
        guard current == generation else { return }
        self.transport = nil
        state = .disconnected
        if let failure { problem = failure }
    }

    public static func statusText(_ state: LinkState, problem: String?) -> String {
        switch state {
        case .disconnected: "Flipper: \(problem ?? "not connected")"
        case .waitingForHello: "Flipper: waiting for the app"
        case .noAnswer: "Flipper: no answer; open SpoolBuddy on the Flipper"
        case .connected(let hello): "Flipper: connected" + (hello.fw.map { " (firmware \($0))" } ?? "")
        }
    }
}

extension BambuddyState {
    /// The status bar's Bambuddy part.
    public var statusText: String {
        switch self {
        case .ready: return "Bambuddy: ready"
        case .unchecked: return "Bambuddy: not checked yet"
        default:
            let message = self.message ?? ""
            return message.hasPrefix("Bambuddy") ? message : "Bambuddy: \(message)"
        }
    }
}
