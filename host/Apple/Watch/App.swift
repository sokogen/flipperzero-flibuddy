import FliBuddyCore
import FliBuddyUI
import SwiftUI

@main
struct FliBuddyWatchApp: App {
    @ViewState private var host: HostModel
    /// Settings arrive from the iPhone; the watch keeps its own Flipper.
    @ViewState private var receiver: WatchSettingsReceiver?

    init() {
        // Before the host model: loading the settings already logs.
        Log.bootstrap(appName: "FliBuddy", level: .info)
        // Bluetooth is the only transport on the watch.
        _host = ViewState(initialValue: HostModel(
            makeTransport: FlipperLink.defaultTransport,
            discoverPorts: { [] }
        ))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(host: host, receiver: receiver)
                .task {
                    if receiver == nil { receiver = WatchSettingsReceiver.start(for: host) }
                    host.start()
                    await host.feed.observe()
                }
        }
    }
}
