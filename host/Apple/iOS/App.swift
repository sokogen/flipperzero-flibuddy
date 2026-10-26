import SpoolBuddyCore
import SpoolBuddyUI
import SwiftUI

@main
struct SpoolBuddyiOSApp: App {
    // Bluetooth is the only transport on iOS; there are no serial ports.
    @ViewState private var host = HostModel(
        makeTransport: FlipperLink.defaultTransport,
        discoverPorts: { [] }
    )

    var body: some Scene {
        WindowGroup {
            RootView(host: host)
                .task {
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
                .navigationTitle("SpoolBuddy")
            } detail: {
                switch section ?? .feed {
                case .feed: feed
                case .settings: settings
                }
            }
        } else {
            TabView {
                Tab("Feed", systemImage: "list.bullet") { feed }
                Tab("Settings", systemImage: "gearshape") { settings }
            }
        }
    }

    private var feed: some View {
        NavigationStack {
            FeedView(feed: host.feed, link: host.link)
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

/// Edits a fresh copy of the saved settings each time it appears.
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
            let model = host.makeSettingsViewModel()
            self.model = model
            Task { await model.loadCatalog() }
        }
    }
}
