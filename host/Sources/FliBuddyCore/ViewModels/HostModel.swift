import Foundation
import Observation

/// Wires the host together: saved settings, the session, the Flipper link and
/// the feed. The app creates one and calls `start()`.
@MainActor
@Observable
public final class HostModel {
    /// Our side of the handshake, e.g. `flibuddy-mac/0.1.0` on `macOS 26.0`.
    public static var hostHello: Hello {
        Hello(app: "\(FliBuddyCore.appName)/\(FliBuddyCore.version)", os: PlatformInfo.current)
    }

    public let session: Session
    public let feed: FeedViewModel
    public let link: FlipperLink
    public private(set) var settings: Settings
    /// Runs after `apply` saved new settings (the iPhone sends them to the watch).
    @ObservationIgnored public var onSettingsSaved: (@MainActor (Settings) -> Void)?

    private let store: SettingsStore
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    private var started = false

    public init(
        store: SettingsStore = SettingsStore(),
        makeInventory: @escaping @Sendable (Settings) throws -> any SpoolInventory = { try $0.makeClient() },
        makeTransport: @escaping @Sendable (TransportChoice) -> any Transport = FlipperLink.defaultTransport,
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
        link.connect(settings.transportChoice)
        Task { await session.checkBambuddy() }
    }

    /// Runs the startup check again (the status bar's Check and Retry, and
    /// Retry on the blocking Spoolman screen).
    public func checkBambuddy() async {
        await session.checkBambuddy()
    }

    /// A status bar button. Settings is the view's to open, so it does
    /// nothing here.
    public func perform(_ action: StatusItem.Action) async {
        switch action {
        case .connect: link.connect(settings.transportChoice)
        case .check, .retry: await checkBambuddy()
        case .settings: break
        }
    }

    /// Saves new settings, points the session at them and checks Bambuddy
    /// again; a changed transport choice (kind, USB port or Bluetooth
    /// peripheral) reconnects a running link.
    public func apply(_ new: Settings) async throws {
        try store.save(new)
        let choiceChanged = new.transportChoice != settings.transportChoice
        settings = new
        onSettingsSaved?(new)
        feed.settings = new
        await session.reconfigure(settings: new, inventory: try? makeInventory(new))
        if choiceChanged, link.isActive { link.connect(new.transportChoice) }
        await session.checkBambuddy()
    }

    /// Remembers `peripheral` as the Bluetooth Flipper, keeping every other
    /// setting as saved now (settings from the iPhone may have arrived since a
    /// Settings screen opened).
    public func useFlipper(_ peripheral: DiscoveredPeripheral) async throws {
        var new = settings
        new.transport = .bluetooth
        new.peripheralId = peripheral.id
        new.peripheralName = peripheral.name
        try await apply(new)
    }

    public func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(
            settings: settings, makeInventory: makeInventory, discoverPorts: discoverPorts,
            discoverFlippers: { [link] in link.discoverFlippers() },
            bluetoothPower: { [link] in await link.bluetoothPowerState() },
            apply: { [weak self] in try await self?.apply($0) }
        )
    }
}
