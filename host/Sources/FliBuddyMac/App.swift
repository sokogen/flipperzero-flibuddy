#if os(macOS)
import AppKit
import FliBuddyCore
import FliBuddyUI
import SwiftUI

@main
struct FliBuddyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var host = HostModel()

    var body: some Scene {
        // One window: the feed and the Flipper link are app-wide.
        Window("FliBuddy", id: "main") {
            FeedView(host: host)
                .frame(minWidth: 760, minHeight: 420)
                .task {
                    host.start()
                    await host.feed.observe()
                }
        }
        .defaultSize(width: 1000, height: 600)
        // `Settings` alone would be FliBuddyCore's settings struct.
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
enum FliBuddyMacUnsupported {
    static func main() {
        print("FliBuddyMac runs on macOS only")
    }
}
#endif
