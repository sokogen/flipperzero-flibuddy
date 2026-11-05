import FliBuddyCore
import FliBuddyUI
import SwiftUI

@main
struct FliBuddyWatchApp: App {
    @ViewState private var host: HostModel
    /// Settings arrive from the iPhone; the watch keeps its own Flipper.
    @ViewState private var receiver: WatchSettingsReceiver?
    @Environment(\.scenePhase) private var scenePhase
    /// Launched with `-FliBuddyDemo YES`: the demo Flipper and Bambuddy
    /// (`DemoFixtures`), no Bluetooth, network, Keychain or settings sync.
    private let isDemo: Bool

    init() {
        // Before the host model: loading the settings already logs.
        Log.bootstrap(appName: "FliBuddy", level: .info)
        isDemo = DemoFixtures.isRequested()
        // Bluetooth is the only transport on the watch.
        _host = ViewState(initialValue: isDemo ? DemoFixtures.makeHost() : HostModel(
            makeTransport: FlipperLink.defaultTransport,
            discoverPorts: { [] }
        ))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(host: host, receiver: receiver)
                .task {
                    // Settings from the iPhone would replace the demo's.
                    if receiver == nil, !isDemo { receiver = WatchSettingsReceiver.start(for: host) }
                    host.start()
                    await host.feed.observe()
                }
                // The watch can also launch locked, before the Keychain is available.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await host.reloadSettings() } }
                }
        }
    }
}
