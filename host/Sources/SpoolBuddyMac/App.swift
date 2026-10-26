#if os(macOS)
import AppKit
import SpoolBuddyCore
import SpoolBuddyUI
import SwiftUI

@main
struct SpoolBuddyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var host = HostModel()

    var body: some Scene {
        // One window: the feed and the Flipper link are app-wide.
        Window("SpoolBuddy", id: "main") {
            FeedView(feed: host.feed, link: host.link)
                .frame(minWidth: 760, minHeight: 420)
                .task {
                    host.start()
                    await host.feed.observe()
                }
        }
        // `Settings` alone would be SpoolBuddyCore's settings struct.
        SwiftUI.Settings {
            SettingsView(host: host)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable, not an app bundle: give it a
        // Dock icon and a menu bar, and bring the window to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#else
/// The package also builds for iOS (the iOS app is `host/Apple/iOS`); there this
/// executable has nothing to run.
@main
enum SpoolBuddyMacUnsupported {
    static func main() {
        print("SpoolBuddyMac runs on macOS only")
    }
}
#endif
