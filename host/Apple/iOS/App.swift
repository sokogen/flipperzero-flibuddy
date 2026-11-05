import FliBuddyCore
import FliBuddyUI
import SwiftUI
import UIKit

/// The one host model, shared by the app and its delegate: on a relaunch
/// for Bluetooth the delegate needs it before any view appears.
@MainActor
enum AppHost {
    /// Launched with `-FliBuddyDemo YES`: the demo Flipper and Bambuddy
    /// (`DemoFixtures`), no Bluetooth, network, Keychain or watch sync.
    static let isDemo = DemoFixtures.isRequested()

    /// The pane the app opens on: the feed, or in the demo the one
    /// `-FliBuddyDemoPane` names (`tools/sim_shot.sh`).
    static let initialPane = DemoFixtures.requestedPane().flatMap(AppPane.init(rawValue:)) ?? .feed

    static let model: HostModel = {
        // Before the host model: loading the settings already logs.
        Log.bootstrap(appName: "FliBuddy", level: .info)
        if isDemo { return DemoFixtures.makeHost() }
        // Bluetooth is the only transport on iOS; there are no serial ports.
        return HostModel(makeTransport: FlipperLink.defaultTransport, discoverPorts: { [] })
    }()
}

/// Starts the link at launch when iOS relaunched the app in the background
/// for Bluetooth, where SwiftUI may never run the views' tasks; and reads
/// the API key again once protected data is available.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let host = AppHost.model
        // The demo's Flipper is no peripheral: creating the central would ask for Bluetooth.
        guard !AppHost.isDemo else { return true }
        let relaunched = CoreBluetoothCentral.restores(launchOptions?[.bluetoothCentrals] as? [String])
        guard HostModel.startsAtLaunch(relaunchedForBluetooth: relaunched, settings: host.settings) else {
            Log.info(.app, "launch: link waits for the views")
            return true
        }
        // State restoration delivers the peripherals only to a central that
        // exists when this returns.
        _ = CoreBluetoothCentral.shared
        Log.notice(.app, "launch: link started, bluetooth_relaunch=\(relaunched)")
        host.start()
        return true
    }

    // A launch while the iPhone is locked (Bluetooth restoration) cannot
    // read the API key; read it again once the data is available.
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Task { await AppHost.model.reloadSettings() }
    }
}

@main
struct FliBuddyiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var host: HostModel
    /// Sends the settings to the Apple Watch after each applied change (not on iPad).
    @ViewState private var watchSync: WatchSettingsSender?
    /// The pane and the Clear confirmation, shared with the menu commands.
    @ViewState private var navigation = AppNavigation(pane: AppHost.initialPane)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _host = ViewState(initialValue: AppHost.model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(host: host, navigation: navigation)
                .task {
                    // The demo's settings must not reach a real watch.
                    if watchSync == nil, !AppHost.isDemo { watchSync = WatchSettingsSender.start(for: host) }
                    // Does nothing when the delegate started the link at launch.
                    host.start()
                    await host.feed.observe()
                }
                // The Spools tab loads again after each write the feed makes.
                .task { await host.spools.observe() }
        }
        // The protected data may have become available while no scene was
        // active; read the key again whenever the app comes to the front.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await host.reloadSettings() } }
        }
        .commands { FeedCommands(host: host, navigation: navigation) }
    }
}

/// The iPad's sidebar in a landscape window, its top tabs in a portrait one
/// (tiles in both), and the iPhone's tabs and cards at a compact width (an
/// iPhone, a narrow multitasking window); see `FeedLayout`. Feed, Spools and
/// Settings in each.
struct RootView: View {
    let host: HostModel
    @Bindable var navigation: AppNavigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Kept as state, so it holds near a square window (`FeedLayout.squareDeadBand`).
    @ViewState private var layout = FeedLayout.cards
    @ViewState private var size: CGSize = .zero
    /// The Settings model lives here, not in `SettingsScreen`: rotating an
    /// iPad swaps the split view and the tabs and builds the screen again,
    /// and a draft being typed must survive that.
    @ViewState private var settingsModel: SettingsViewModel?

    private func updateLayout() {
        layout = FeedLayout.forWindow(
            width: size.width, height: size.height, isCompact: sizeClass != .regular, previous: layout
        )
    }

    var body: some View {
        Group {
            switch layout {
            case .sidebar:
                NavigationSplitView {
                    PadSidebar(host: host, navigation: navigation)
                        .navigationSplitViewColumnWidth(FeedLayout.sidebarWidth)
                } detail: {
                    switch navigation.pane {
                    case .feed: feed
                    case .spools: spools
                    case .settings: settings
                    }
                }
            case .tabs, .cards:
                // iPadOS draws the tab bar at the top, iOS at the bottom.
                TabView(selection: $navigation.pane) {
                    Tab("Feed", systemImage: "list.bullet", value: AppPane.feed) { feed }
                    Tab(SpoolsViewModel.title, systemImage: "shippingbox", value: AppPane.spools) { spools }
                    Tab("Settings", systemImage: "gearshape", value: AppPane.settings) { settings }
                }
            }
        }
        .environment(\.feedLayout, layout)
        .settingsSession(settingsModel, showing: navigation.pane == .settings)
        // The whole window, the safe areas and the keyboard included: the
        // keyboard rising on a portrait iPad must not make it look landscape
        // (`ignoresSafeArea` does not change what the geometry reports).
        .onGeometryChange(for: CGSize.self) { proxy in
            let insets = proxy.safeAreaInsets
            let window = FeedLayout.windowSize(
                width: proxy.size.width, height: proxy.size.height, top: insets.top, bottom: insets.bottom,
                leading: insets.leading, trailing: insets.trailing
            )
            return CGSize(width: window.width, height: window.height)
        } action: { size = $0 }
        .onChange(of: size) { updateLayout() }
        .onChange(of: sizeClass, initial: true) { updateLayout() }
    }

    private var feed: some View {
        NavigationStack {
            FeedView(
                host: host, openSettings: { navigation.pane = .settings },
                scanForFlipper: { navigation.scanForFlipper() }, confirmingClear: $navigation.confirmingClear
            )
                .navigationTitle("Feed")
        }
    }

    /// Bambuddy's inventory, read-only.
    private var spools: some View {
        NavigationStack {
            SpoolsView(model: host.spools, openSettings: { navigation.pane = .settings })
        }
    }

    private var settings: some View {
        NavigationStack {
            SettingsScreen(host: host, model: $settingsModel, navigation: navigation)
                .navigationTitle("Settings")
        }
    }
}

/// The settings, applied as they change (no Save on iPhone and iPad). The
/// model is made once and kept by `RootView`, so a field being typed
/// survives switching tabs, panes and layouts; leaving the screen commits it.
struct SettingsScreen: View {
    let host: HostModel
    @Binding var model: SettingsViewModel?
    let navigation: AppNavigation

    var body: some View {
        Group {
            if let model {
                SettingsForm(model: model)
                    // Each time Settings comes on screen, not only the first.
                    // Not `.task`: leaving the tab would cancel the load and
                    // show the cancellation as the catalog's error.
                    .onAppear { Task { await model.opened() } }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil { model = host.makeSettingsViewModel(appliesOnChange: true) }
            startRequestedScan()
        }
        .onChange(of: navigation.scanRequested) { startRequestedScan() }
        // The API key was read again after a launch while locked.
        .onChange(of: host.settings) { _, settings in model?.adoptRestoredAPIKey(settings) }
    }

    /// The empty feed's Scan for Flipper: the scan, and with it the
    /// Bluetooth permission prompt, starts here.
    private func startRequestedScan() {
        guard navigation.scanRequested, let model else { return }
        navigation.scanRequested = false
        Log.info(.settings, "scan for flipper: from the empty feed")
        if !model.isScanning { model.scanForFlippers() }
    }
}
