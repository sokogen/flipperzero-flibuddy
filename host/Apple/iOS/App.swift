import FliBuddyCore
import FliBuddyUI
import SwiftUI

@main
struct FliBuddyiOSApp: App {
    @ViewState private var host: HostModel
    /// Sends the settings to the Apple Watch after each applied change (not on iPad).
    @ViewState private var watchSync: WatchSettingsSender?
    /// The pane and the Clear confirmation, shared with the menu commands.
    @ViewState private var navigation = AppNavigation()

    init() {
        // Before the host model: loading the settings already logs.
        Log.bootstrap(appName: "FliBuddy", level: .info)
        // Bluetooth is the only transport on iOS; there are no serial ports.
        _host = ViewState(initialValue: HostModel(
            makeTransport: FlipperLink.defaultTransport,
            discoverPorts: { [] }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(host: host, navigation: navigation)
                .task {
                    if watchSync == nil { watchSync = WatchSettingsSender.start(for: host) }
                    host.start()
                    await host.feed.observe()
                }
        }
        .commands { FeedCommands(host: host, navigation: navigation) }
    }
}

/// The iPad's sidebar and one-line table when the window leaves 900 pt
/// beside the sidebar (landscape), else the iPhone's tabs and cards (an
/// iPhone, a portrait iPad); see `FeedLayout`.
struct RootView: View {
    let host: HostModel
    @Bindable var navigation: AppNavigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var width: CGFloat = 0

    private var layout: FeedLayout {
        FeedLayout.forWindow(width: width, isCompact: sizeClass != .regular)
    }

    var body: some View {
        Group {
            switch layout {
            case .table:
                NavigationSplitView {
                    PadSidebar(host: host, navigation: navigation)
                        .navigationSplitViewColumnWidth(FeedLayout.sidebarWidth)
                } detail: {
                    switch navigation.pane {
                    case .feed: feed
                    case .settings: settings
                    }
                }
            case .cards:
                TabView(selection: $navigation.pane) {
                    Tab("Feed", systemImage: "list.bullet", value: AppPane.feed) { feed }
                    Tab("Settings", systemImage: "gearshape", value: AppPane.settings) { settings }
                }
            }
        }
        .environment(\.feedLayout, layout)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var feed: some View {
        NavigationStack {
            FeedView(host: host, openSettings: { navigation.pane = .settings }, confirmingClear: $navigation.confirmingClear)
                .navigationTitle("Feed")
        }
    }

    private var settings: some View {
        NavigationStack {
            SettingsScreen(host: host)
                .navigationTitle("Settings")
        }
    }
}

/// The settings, applied as they change (no Save on iPhone and iPad). The
/// model is made once, so a field being typed survives switching tabs; leaving
/// the tab commits it.
struct SettingsScreen: View {
    let host: HostModel
    @ViewState private var model: SettingsViewModel?

    var body: some View {
        Group {
            if let model {
                SettingsForm(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard model == nil else { return }
            let model = host.makeSettingsViewModel(appliesOnChange: true)
            self.model = model
            Task { await model.loadCatalog() }
        }
    }
}
