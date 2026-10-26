import SpoolBuddyCore
import SpoolBuddyUI
import SwiftUI

@main
struct SpoolBuddyWatchApp: App {
    // Bluetooth is the only transport on the watch.
    @ViewState private var host = HostModel(
        makeTransport: FlipperLink.defaultTransport,
        discoverPorts: { [] }
    )
    /// Settings arrive from the iPhone; the watch keeps its own Flipper.
    @ViewState private var receiver: WatchSettingsReceiver?

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    WatchFeedView(feed: host.feed, link: host.link)
                }
                NavigationStack {
                    WatchSettingsView(host: host, receiver: receiver)
                }
            }
            .tabViewStyle(.verticalPage)
            .task {
                if receiver == nil { receiver = WatchSettingsReceiver.start(for: host) }
                host.start()
                await host.feed.observe()
            }
        }
    }
}
