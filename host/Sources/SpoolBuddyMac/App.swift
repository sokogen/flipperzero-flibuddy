import SpoolBuddyCore
import SwiftUI

@main
struct SpoolBuddyMacApp: App {
    var body: some Scene {
        WindowGroup("SpoolBuddy") {
            Text("SpoolBuddy \(SpoolBuddyCore.appName)")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
