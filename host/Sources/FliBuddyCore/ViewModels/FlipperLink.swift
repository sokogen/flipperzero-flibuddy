import Foundation
import Observation

/// How to reach the Flipper.
public enum TransportChoice: Equatable, Sendable {
    /// The serial port; `nil` uses the first Flipper port found.
    case usb(port: String?)
    /// The remembered peripheral; `nil` uses the first Flipper found.
    case bluetooth(peripheral: UUID?)
}

/// Keeps the Flipper connected: opens the chosen transport (for USB the chosen
/// port or the first Flipper found), runs the `hello` handshake, hands every
/// Flipper message to the session and sends its reply. A dropped or failed
/// link, or a reply that cannot be sent, is retried after `retryDelay` until
/// `disconnect()`.
@MainActor
@Observable
public final class FlipperLink {
    public static let noFlipperFound = "No Flipper found"

    public private(set) var state: LinkState = .disconnected
    /// The USB port in use or being opened.
    public private(set) var port: String?
    /// The transport asked for.
    public private(set) var choice: TransportChoice?
    /// Why the link is down, if it is not just closed.
    public private(set) var problem: String?
    public private(set) var isActive = false

    public var statusText: String { Self.statusText(state, problem: problem) }

    /// How the Flipper is connected once it said hello; `nil` before.
    public var connectedTransport: TransportKind? { Self.connectedTransport(state, choice: choice) }

    public static func connectedTransport(_ state: LinkState, choice: TransportChoice?) -> TransportKind? {
        guard case .connected = state else { return nil }
        return switch choice {
        case .usb: .usb
        case .bluetooth: .bluetooth
        case nil: nil
        }
    }

    private let session: Session
    private let hello: Hello
    private let makeTransport: @Sendable (TransportChoice) -> any Transport
    private let discoverPorts: @Sendable () -> [String]
    private let scanPeripherals: @Sendable () -> AsyncStream<DiscoveredPeripheral>
    private let bluetoothPower: @Sendable () async -> BLEPowerState
    private let retryDelay: Duration
    private var loop: Task<Void, Never>?
    private var transport: (any Transport)?
    /// Bumped by `connect` and `disconnect`; a stale loop changes nothing.
    private var generation = 0

    public init(
        session: Session, hello: Hello,
        makeTransport: @escaping @Sendable (TransportChoice) -> any Transport = FlipperLink.defaultTransport,
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() },
        scanPeripherals: @escaping @Sendable () -> AsyncStream<DiscoveredPeripheral> = FlipperLink.defaultScan,
        bluetoothPower: @escaping @Sendable () async -> BLEPowerState = FlipperLink.defaultPowerState,
        retryDelay: Duration = .seconds(2)
    ) {
        self.session = session
        self.hello = hello
        self.makeTransport = makeTransport
        self.discoverPorts = discoverPorts
        self.scanPeripherals = scanPeripherals
        self.bluetoothPower = bluetoothPower
        self.retryDelay = retryDelay
    }

    /// `SerialTransport` for USB, `BLETransport` on the shared CoreBluetooth
    /// central for Bluetooth. A USB choice always names the port here.
    public nonisolated static func defaultTransport(_ choice: TransportChoice) -> any Transport {
        switch choice {
        case .usb(let port):
            return SerialTransport(path: port ?? "")
        case .bluetooth(let peripheral):
            #if canImport(CoreBluetooth)
            return BLETransport(central: CoreBluetoothCentral.shared, peripheral: peripheral)
            #else
            preconditionFailure("Bluetooth needs CoreBluetooth")
            #endif
        }
    }

    /// Flippers advertising the FliBuddy service, on the shared central.
    public nonisolated static func defaultScan() -> AsyncStream<DiscoveredPeripheral> {
        #if canImport(CoreBluetooth)
        CoreBluetoothCentral.shared.scan(service: FliBuddyGATT.service)
        #else
        AsyncStream { $0.finish() }
        #endif
    }

    /// The radio state of the shared central.
    public nonisolated static func defaultPowerState() async -> BLEPowerState {
        #if canImport(CoreBluetooth)
        await CoreBluetoothCentral.shared.powerState()
        #else
        .unsupported
        #endif
    }

    /// (Re)starts the link with `choice`.
    public func connect(_ choice: TransportChoice) {
        disconnect()
        self.choice = choice
        isActive = true
        let current = generation
        loop = Task { await self.run(choice, generation: current) }
    }

    /// Flippers advertising over Bluetooth, as they are found, for the
    /// settings picker; scanning stops when the consumer stops iterating.
    public func discoverFlippers() -> AsyncStream<DiscoveredPeripheral> {
        scanPeripherals()
    }

    /// The Bluetooth radio state, for telling an empty scan from a radio that
    /// is off or not allowed.
    public func bluetoothPowerState() async -> BLEPowerState {
        await bluetoothPower()
    }

    public func disconnect() {
        if isActive { Log.info(.link, "disconnect") }
        generation += 1
        loop?.cancel()
        loop = nil
        transport?.disconnect()
        transport = nil
        isActive = false
        problem = nil
        setState(.disconnected)
        port = nil
    }

    private func run(_ choice: TransportChoice, generation current: Int) async {
        while !Task.isCancelled, current == generation {
            if let resolved = resolve(choice) {
                await runOnce(resolved, generation: current)
                guard !Task.isCancelled, current == generation else { return }
                Log.info(.link, "retry: in=\(retryDelay.logDescription)")
            } else {
                // Logged once: the search repeats until a Flipper turns up.
                if problem != Self.noFlipperFound { Log.notice(.link, "problem: \(Self.noFlipperFound)") }
                problem = Self.noFlipperFound
                Log.debug(.link, "retry: in=\(retryDelay.logDescription)")
            }
            try? await Task.sleep(for: retryDelay)
        }
    }

    /// Changes `state`, logging the transition and, once the link is down,
    /// the problem.
    private func setState(_ new: LinkState) {
        let old = state
        state = new
        guard new != old else { return }
        let problem = new == .disconnected ? problem.map { " problem=\"\($0)\"" } ?? "" : ""
        Log.info(.link, "state: \(old.logName) -> \(new.logName)\(problem)")
    }

    /// The choice with the USB port filled in; `nil` when no port is found.
    /// Bluetooth looks for the peripheral while connecting.
    private func resolve(_ choice: TransportChoice) -> TransportChoice? {
        switch choice {
        case .usb(let port): (port ?? discoverPorts().first).map { .usb(port: $0) }
        case .bluetooth: choice
        }
    }

    private func runOnce(_ choice: TransportChoice, generation current: Int) async {
        Log.info(.link, "connect: \(choice.logFields)")
        let transport = makeTransport(choice)
        let link = TransportSession(transport: transport, hello: hello)
        self.transport = transport
        if case .usb(let path) = choice { port = path }
        let pump = Task {
            for await event in link.events {
                guard current == self.generation else { return }
                switch event {
                case .state(let state):
                    if state != .disconnected { self.problem = nil }
                    self.setState(state)
                case .message(let message):
                    guard let reply = await self.session.handle(message) else { continue }
                    do {
                        try await link.send(reply)
                    } catch {
                        // The Flipper would wait for a reply that never comes:
                        // drop the link so it sees the host go, and reconnect.
                        guard current == self.generation else { return }
                        self.problem = Session.describe(error)
                        Log.error(.link, "reply failed: type=\(reply.type) error=\(Session.describe(error))")
                        await link.disconnect()
                        return
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
        if let failure {
            Log.error(.link, "connect failed: error=\(failure)")
            problem = failure
        }
        setState(.disconnected)
    }

    /// "Flipper speaks protocol 1, host speaks 2".
    public static func versionMismatchText(_ version: Int) -> String {
        WireLog.versionMismatch(version)
    }

    /// What to update when the two sides speak different protocol versions.
    public static func versionMismatchAdvice(_ version: Int) -> String {
        version < Message.version
            ? "Install the matching FliBuddy app on the Flipper"
            : "Update FliBuddy on this device"
    }

    public static func statusText(_ state: LinkState, problem: String?) -> String {
        switch state {
        case .disconnected: "Flipper: \(problem ?? "not connected")"
        case .waitingForHello: "Flipper: waiting for the app"
        case .noAnswer: "Flipper: no answer; open FliBuddy on the Flipper"
        case .otherVersion(let version): "Flipper: speaks protocol \(version), host speaks \(Message.version)"
        case .connected(let hello): "Flipper: connected" + (hello.fw.map { " (firmware \($0))" } ?? "")
        }
    }
}

extension TransportChoice {
    /// `transport=usb port=/dev/…` or `transport=bluetooth peripheral=<uuid>`;
    /// `any` when none was chosen.
    var logFields: String {
        switch self {
        case .usb(let port): "transport=usb port=\(port ?? "any")"
        case .bluetooth(let peripheral): "transport=bluetooth peripheral=\(peripheral?.uuidString ?? "any")"
        }
    }
}

extension LinkState {
    /// The state's name, without the Flipper's `hello`: it is logged when it arrives.
    var logName: String {
        switch self {
        case .disconnected: "disconnected"
        case .waitingForHello: "waitingForHello"
        case .noAnswer: "noAnswer"
        case .otherVersion(let version): "otherVersion(\(version))"
        case .connected: "connected"
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
