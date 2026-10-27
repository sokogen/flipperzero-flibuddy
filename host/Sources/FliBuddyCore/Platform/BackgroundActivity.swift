#if os(iOS)
import UIKit
#endif

/// Work that should finish even if the app goes to the background meanwhile.
/// On iOS it runs inside a UIKit background task, so a Bambuddy request that
/// a Bluetooth event started while the screen is locked is not frozen half
/// way; iOS ends the task after about 30 s at most. Elsewhere it just runs.
enum BackgroundActivity {
    static func run<T: Sendable>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        #if os(iOS)
        let task = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: name) {
                Log.notice(.app, "background time ran out: \(name)")
            }
        }
        defer {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
        }
        #endif
        return try await body()
    }
}
