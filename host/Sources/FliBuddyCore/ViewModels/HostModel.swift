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
    /// The Spools tab (iPhone and iPad).
    public let spools: SpoolsViewModel
    public let link: FlipperLink
    public private(set) var settings: Settings
    /// Runs after `apply` saved new settings (the iPhone sends them to the watch).
    @ObservationIgnored public var onSettingsSaved: (@MainActor (Settings) -> Void)?

    /// The watch sync state for the Settings screen (iPhone only); set by
    /// `WatchSettingsSender.start(for:)`.
    @ObservationIgnored public var watchSyncState: (@MainActor () -> WatchSyncState?)?

    private let store: SettingsStore
    private let makeInventory: @Sendable (Settings) throws -> any SpoolInventory
    private let discoverPorts: @Sendable () -> [String]
    /// See `init`'s `linkWaitsForChosenFlipper`.
    private let linkWaitsForChosenFlipper: Bool
    private let requiresHTTPS: Bool
    private var started = false

    /// `scanPeripherals` and `bluetoothPower` stand in for CoreBluetooth, `now`
    /// for the clock of the feed's scan times (the demo mode, tests).
    /// `linkWaitsForChosenFlipper` (the Bluetooth-only iPhone, iPad and
    /// Watch): without a remembered Flipper the link does not start until
    /// one is chosen, as creating the Bluetooth central asks for permission
    /// and that belongs to Scan for Flipper.
    public init(
        store: SettingsStore = SettingsStore(),
        makeInventory: @escaping @Sendable (Settings) throws -> any SpoolInventory = { try $0.makeClient() },
        makeTransport: @escaping @Sendable (TransportChoice) -> any Transport = FlipperLink.defaultTransport,
        discoverPorts: @escaping @Sendable () -> [String] = { SerialTransport.discoverFlipperPorts() },
        scanPeripherals: @escaping @Sendable () -> AsyncStream<DiscoveredPeripheral> = FlipperLink.defaultScan,
        bluetoothPower: @escaping @Sendable () async -> BLEPowerState = FlipperLink.defaultPowerState,
        now: @escaping @Sendable () -> Date = { Date() },
        linkWaitsForChosenFlipper: Bool = TransportKind.available == [.bluetooth],
        requiresHTTPS: Bool = Settings.requiresHTTPS
    ) {
        let settings = store.load()
        self.settings = settings
        self.store = store
        self.makeInventory = makeInventory
        self.discoverPorts = discoverPorts
        self.linkWaitsForChosenFlipper = linkWaitsForChosenFlipper
        self.requiresHTTPS = requiresHTTPS
        session = Session(settings: settings, inventory: try? makeInventory(settings), now: now, requiresHTTPS: requiresHTTPS)
        feed = FeedViewModel(session: session, settings: settings)
        spools = SpoolsViewModel(session: session, feed: feed, settings: settings, now: now)
        link = FlipperLink(
            session: session, hello: Self.hostHello, makeTransport: makeTransport, discoverPorts: discoverPorts,
            scanPeripherals: scanPeripherals, bluetoothPower: bluetoothPower
        )
    }

    /// Connects the Flipper and runs the startup check, once: a later call
    /// (another window) keeps the running link. A link that waits for a
    /// Flipper to be chosen starts when one is (`apply`).
    public func start() {
        guard !started else { return }
        started = true
        if startsLink(settings) {
            link.connect(settings.transportChoice)
        } else {
            Log.info(.link, "start: waits for a Flipper to be chosen")
        }
        Task { await session.checkBambuddy() }
    }

    /// Whether the link may run with `settings`: always, unless it waits
    /// for a chosen Flipper and Bluetooth remembers none.
    private func startsLink(_ settings: Settings) -> Bool {
        !linkWaitsForChosenFlipper || settings.transport != .bluetooth || settings.peripheralId != nil
    }

    /// What the empty feed says: no server, no Flipper, or hold a tag.
    public var feedEmptyState: FeedEmptyState {
        FeedEmptyState.of(
            settings: settings, requiresHTTPS: requiresHTTPS, flipperConnected: link.connectedTransport != nil
        )
    }

    /// Whether the iOS app delegate starts the link at launch, before any
    /// view appears (a relaunch in the background may never show one):
    /// iOS relaunched the app for a Bluetooth event, or a Bluetooth Flipper
    /// is remembered. A fresh install leaves it to the views, as creating the
    /// central asks for Bluetooth permission.
    public static func startsAtLaunch(relaunchedForBluetooth: Bool, settings: Settings) -> Bool {
        relaunchedForBluetooth || (settings.transport == .bluetooth && settings.peripheralId != nil)
    }

    /// Runs the startup check again (the status bar's Check and Retry, and
    /// Retry on the blocking Spoolman screen).
    public func checkBambuddy() async {
        await session.checkBambuddy()
    }

    /// The iPhone's banner over the feed, from both halves of the status bar.
    public var connectionBanner: ConnectionBanner {
        ConnectionBanner(flipper: link.statusItem, bambuddy: feed.bambuddyStatus)
    }

    /// The watch's connection glyph, from both halves of the status bar.
    public var watchGlyph: StatusItem {
        WatchGlyph.status(flipper: link.statusItem, bambuddy: feed.bambuddyStatus)
    }

    /// The iPad sidebar: both connection rows, the feed's count, Clear.
    public var sidebar: Sidebar {
        Sidebar(
            flipper: link.statusItem, bambuddy: feed.bambuddyStatus, flipperName: settings.peripheralName,
            serverURL: settings.baseURL, feedCount: feed.items.count, spoolCount: spools.activeCount
        )
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
    /// peripheral) reconnects a running link. Only another URL or key
    /// reconfigures the session (its rows' spools may belong to the old
    /// Bambuddy); other changes leave the feed as it is.
    public func apply(_ new: Settings) async throws {
        var new = new
        // A screen that still shows the key as unknown must not put it back
        // after the key was read again.
        if new.apiKeyUnknown, !settings.apiKeyUnknown, new.trimmedAPIKey.isEmpty {
            new.apiKey = settings.apiKey
            new.apiKeyUnknown = false
        }
        try store.save(new)
        let choiceChanged = new.transportChoice != settings.transportChoice
        let serverChanged = Self.serverChanged(from: settings, to: new)
        settings = new
        onSettingsSaved?(new)
        feed.settings = new
        spools.settings = new
        // The Spools list belongs to the old Bambuddy: gone at once, loaded
        // again after the check below.
        var reloadSpools = false
        if serverChanged {
            await session.reconfigure(settings: new, inventory: try? makeInventory(new))
            reloadSpools = spools.forgetList()
        } else {
            // Reconfiguring would forget the spools created on scan (Link
            // could no longer delete them) and reload the colour map.
            await session.update(settings: new)
        }
        Log.info(.settings, "apply: server=\(serverChanged ? "changed" : "same")")
        if started, !link.isActive, startsLink(new) {
            // The first Flipper chosen: the link that waited starts.
            Log.info(.link, "start: a Flipper was chosen")
            link.connect(new.transportChoice)
        } else if choiceChanged, link.isActive {
            link.connect(new.transportChoice)
        }
        await session.checkBambuddy()
        if reloadSpools { await spools.refresh() }
    }

    /// Whether `new` may name another Bambuddy or another key than `old`.
    static func serverChanged(from old: Settings, to new: Settings) -> Bool {
        old.baseURL != new.baseURL || old.apiKey != new.apiKey
    }

    /// Reads the API key again when it was unknown (the Keychain was locked at
    /// launch): on protected data becoming available and when the app becomes
    /// active. A key that reads now replaces the unknown one; every other
    /// setting stays as it is, the session is reconfigured and the watch gets
    /// the key. Does nothing when the key is known or still unreadable.
    public func reloadSettings() async {
        guard settings.apiKeyUnknown else { return }
        let loaded = store.load()
        guard !loaded.apiKeyUnknown else {
            Log.info(.settings, "reload: the API key is still unreadable")
            return
        }
        var new = settings
        new.apiKey = loaded.apiKey
        new.apiKeyUnknown = false
        Log.info(.settings, "reload: the API key is back, key=\(loaded.apiKey.isEmpty ? "absent" : "present")")
        settings = new
        onSettingsSaved?(new)
        feed.settings = new
        spools.settings = new
        await session.reconfigure(settings: new, inventory: try? makeInventory(new))
        let reloadSpools = spools.forgetList()
        await session.checkBambuddy()
        if reloadSpools { await spools.refresh() }
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

    /// The Settings screen's model; the iPhone and iPad pass
    /// `appliesOnChange`, the Mac keeps its Save.
    public func makeSettingsViewModel(appliesOnChange: Bool = false) -> SettingsViewModel {
        SettingsViewModel(
            settings: settings, makeInventory: makeInventory, discoverPorts: discoverPorts,
            discoverFlippers: { [link] in link.discoverFlippers() },
            bluetoothPower: { [link] in await link.bluetoothPowerState() },
            connectedTransport: { [link] in link.connectedTransport },
            appliesOnChange: appliesOnChange,
            watchSync: { [weak self] in self?.watchSyncState?() },
            apply: { [weak self] in try await self?.apply($0) }
        )
    }
}
