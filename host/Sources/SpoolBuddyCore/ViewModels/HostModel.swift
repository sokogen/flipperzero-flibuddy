import Foundation
import Observation

/// Wires the host together: saved settings, the session, the Flipper link and
/// the feed. The app creates one and calls `start()`.
@MainActor
@Observable
public final class HostModel {
    /// Our side of the handshake, e.g. `spoolbuddy-mac/0.1.0` on `macOS 26.0`.
    public static var hostHello: Hello {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Hello(
            app: "\(SpoolBuddyCore.appName)/\(SpoolBuddyCore.version)",
            os: "macOS \(version.majorVersion).\(version.minorVersion)"
        )
    }

    public let session: Session
    public let feed: FeedViewModel
    public let link: FlipperLink
    public private(set) var settings: Settings

    private let store: SettingsStore
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    private var started = false

    public init(
        store: SettingsStore = SettingsStore(),
        makeInventory: @escaping @Sendable (Settings) throws -> any SpoolInventory = { try $0.makeClient() },
        makeTransport: @escaping @Sendable (String) -> any Transport = { SerialTransport(path: $0) },
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() }
    ) {
        let settings = store.load()
        self.settings = settings
        self.store = store
        self.makeInventory = makeInventory
        self.discoverPorts = discoverPorts
        session = Session(settings: settings, inventory: try? makeInventory(settings))
        feed = FeedViewModel(session: session, settings: settings)
        link = FlipperLink(
            session: session, hello: Self.hostHello, makeTransport: makeTransport, discoverPorts: discoverPorts
        )
    }

    /// Connects the Flipper and runs the startup check, once: a later call
    /// (another window) keeps the running link.
    public func start() {
        guard !started else { return }
        started = true
        link.connect(port: settings.port)
        Task { await session.checkBambuddy() }
    }

    /// Saves new settings, points the session at them and checks Bambuddy
    /// again; a changed port reconnects a running link.
    public func apply(_ new: Settings) async throws {
        try store.save(new)
        let portChanged = new.port != settings.port
        settings = new
        feed.settings = new
        await session.reconfigure(settings: new, inventory: try? makeInventory(new))
        if portChanged, link.isActive { link.connect(port: new.port) }
        await session.checkBambuddy()
    }

    public func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(
            settings: settings, makeInventory: makeInventory, discoverPorts: discoverPorts,
            apply: { [weak self] in try await self?.apply($0) }
        )
    }
}
