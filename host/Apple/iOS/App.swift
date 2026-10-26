import FliBuddyCore
import FliBuddyUI
import SwiftUI

@main
struct FliBuddyiOSApp: App {
    @ViewState private var host: HostModel
    /// Sends the settings to the Apple Watch after each save (not on iPad).
    @ViewState private var watchSync: WatchSettingsSender?

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
            RootView(host: host)
                .task {
                    if watchSync == nil { watchSync = WatchSettingsSender.start(for: host) }
                    host.start()
                    await host.feed.observe()
                }
        }
    }
}

/// A split view with a sidebar on iPad (regular width), tabs on iPhone.
struct RootView: View {
    let host: HostModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewState private var section: Section? = .feed

    enum Section: Hashable {
        case feed, settings
    }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(selection: $section) {
                    Label("Feed", systemImage: "list.bullet").tag(Section.feed)
                    Label("Settings", systemImage: "gearshape").tag(Section.settings)
                }
                .navigationTitle("FliBuddy")
            } detail: {
                switch section ?? .feed {
                case .feed: feed
                case .settings: settings
                }
            }
        } else {
            TabView(selection: $section) {
                Tab("Feed", systemImage: "list.bullet", value: Section?.some(.feed)) { feed }
                Tab("Settings", systemImage: "gearshape", value: Section?.some(.settings)) { settings }
            }
        }
    }

    private var feed: some View {
        NavigationStack {
            FeedView(host: host) { section = .settings }
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

/// Edits a copy of the saved settings. The copy is made once, so unsaved edits
/// (a scanned QR code too) survive switching tabs.
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
            let model = host.makeSettingsViewModel()
            self.model = model
            Task { await model.loadCatalog() }
        }
    }
}
