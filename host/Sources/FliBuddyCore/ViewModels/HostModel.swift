import Foundation
import Observation

/// Wires the host together: saved settings, the session, the Flipper link and
/// the feed. The app creates one and calls `start()`.
@MainActor
@Observable
public final class HostModel {
    /// Our side of the handshake, e.g. `flibuddy-ios/1.0.0` on `iOS 26.1`:
    /// the platform's app and the bundle's version.
    public static var hostHello: Hello {
        Hello(app: FliBuddyCore.app(PlatformInfo.currentFamily, info: Bundle.main.infoDictionary), os: PlatformInfo.current)
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
    /// `linkWaitsForChosenFlipper` (default on Bluetooth-only platforms; the
    /// iPhone and iPad keep it, the watch passes false and connects to the
    /// first Flipper found): without a remembered Flipper the link does not
    /// start until one is chosen, as creating the Bluetooth central asks for
    /// permission and that belongs to Scan for Flipper. Forgetting the
    /// Flipper stops it again.
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
    /// for a chosen Flipper and Bluetooth remembers none, or the settings
    /// that would name it could not be read yet.
    private func startsLink(_ settings: Settings) -> Bool {
        guard linkWaitsForChosenFlipper else { return true }
        if settings.protectedDataUnavailable { return false }
        return settings.transport != .bluetooth || settings.peripheralId != nil
    }

    /// What the empty feed says: no server, no Flipper, or hold a tag.
    public var feedEmptyState: FeedEmptyState {
        FeedEmptyState.of(
            settings: settings, requiresHTTPS: requiresHTTPS, flipperConnected: link.connectedTransport != nil
        )
    }

    /// Whether the iOS app delegate starts the link at launch, before any
    /// view appears (a relaunch in the background may never show one): a
    /// Bluetooth Flipper is remembered, whether or not iOS relaunched the app
    /// for it. Without one the link waits for a Flipper to be chosen, so a
    /// relaunch for Bluetooth would create the central for nothing; a fresh
    /// install leaves it to Scan for Flipper, as creating the central asks
    /// for Bluetooth permission. A relaunch for Bluetooth before the first
    /// unlock cannot read which Flipper is remembered; it starts too, as iOS
    /// delivers the restored peripherals only to a central that exists when
    /// launching returns, and the link waits for `reloadSettings`.
    public static func startsAtLaunch(relaunchedForBluetooth: Bool, settings: Settings) -> Bool {
        if settings.protectedDataUnavailable { return relaunchedForBluetooth }
        return settings.transport == .bluetooth && settings.peripheralId != nil
    }

    /// Runs the startup check again (the status bar's Check and Retry, and
    /// Retry on the blocking Spoolman screen).
    public func checkBambuddy() async {
        await session.checkBambuddy()
    }

    /// The iPhone's banner over the feed, from both halves of the status
    /// bar; beside an empty feed that shows a setup step, without the lines
    /// that say the same.
    public var connectionBanner: ConnectionBanner {
        let showsEmptyState = feed.items.isEmpty && !feed.isBlocked
        return ConnectionBanner(
            flipper: link.statusItem, bambuddy: feed.bambuddyStatus,
            emptyState: showsEmptyState ? feedEmptyState : nil
        )
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
        // Settings loaded before the first unlock are defaults: saving them
        // (or what an edit made of them) would overwrite the stored ones.
        if settings.protectedDataUnavailable { new.protectedDataUnavailable = true }
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
        updateLink(new, choiceChanged: choiceChanged)
        await session.checkBambuddy()
        if reloadSpools { await spools.refresh() }
    }

    /// Starts, stops or moves the link for settings that just took effect.
    private func updateLink(_ new: Settings, choiceChanged: Bool) {
        if started, !link.isActive, startsLink(new) {
            // The first Flipper chosen (or read after the first unlock): the
            // link that waited starts.
            Log.info(.link, "start: a Flipper was chosen")
            link.connect(new.transportChoice)
        } else if link.isActive, !startsLink(new) {
            // Forget This Flipper where the link waits for a chosen one: it
            // must not reconnect to the first Flipper found.
            Log.info(.link, "stop: no Flipper chosen")
            link.disconnect()
        } else if choiceChanged, link.isActive {
            link.connect(new.transportChoice)
        }
    }

    /// Whether `new` may name another Bambuddy or another key than `old`.
    static func serverChanged(from old: Settings, to new: Settings) -> Bool {
        old.baseURL != new.baseURL || old.apiKey != new.apiKey
    }

    /// Reads the settings again when the launch could not (the Keychain was
    /// locked): on protected data becoming available and when the app
    /// becomes active. Before the first unlock nothing was readable
    /// (`protectedDataUnavailable`): every setting now read replaces the
    /// defaults, and the link starts or moves to the remembered Flipper.
    /// Otherwise only the key was unknown: a key that reads now replaces it
    /// and every other setting stays as it is. Either way the session is
    /// reconfigured and the watch gets what was read (`onSettingsSaved`);
    /// nothing is saved. Does nothing when everything is known or still
    /// unreadable.
    public func reloadSettings() async {
        guard settings.apiKeyUnknown || settings.protectedDataUnavailable else { return }
        let loaded = store.load()
        guard !loaded.apiKeyUnknown, !loaded.protectedDataUnavailable else {
            Log.info(.settings, "reload: the settings are still unreadable")
            return
        }
        let new: Settings
        if settings.protectedDataUnavailable {
            new = loaded
            Log.info(.settings, "reload: the settings are back after the first unlock")
        } else {
            var merged = settings
            merged.apiKey = loaded.apiKey
            merged.apiKeyUnknown = false
            new = merged
            Log.info(.settings, "reload: the API key is back, key=\(loaded.apiKey.isEmpty ? "absent" : "present")")
        }
        let choiceChanged = new.transportChoice != settings.transportChoice
        settings = new
        onSettingsSaved?(new)
        feed.settings = new
        spools.settings = new
        await session.reconfigure(settings: new, inventory: try? makeInventory(new))
        let reloadSpools = spools.forgetList()
        updateLink(new, choiceChanged: choiceChanged)
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
        let model = SettingsViewModel(
            settings: settings, makeInventory: makeInventory, discoverPorts: discoverPorts,
            discoverFlippers: { [link] in link.discoverFlippers() },
            bluetoothPower: { [link] in await link.bluetoothPowerState() },
            connectedTransport: { [link] in link.connectedTransport },
            appliesOnChange: appliesOnChange,
            watchSync: { [weak self] in self?.watchSyncState?() },
            apply: { [weak self] in try await self?.apply($0) }
        )
        settingsModelHook?(model)
        return model
    }

    /// The demo's `-FliBuddyDemoQR YES`: runs on each new Settings model.
    public var settingsModelHook: ((SettingsViewModel) -> Void)?
}
