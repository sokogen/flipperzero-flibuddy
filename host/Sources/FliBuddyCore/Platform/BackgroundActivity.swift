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
        try await run(name, system: UIKitBackgroundTasks(), body)
        #else
        try await body()
        #endif
    }

    /// `body` inside a background task of `system`. The task ends when the
    /// work ends, or when its time runs out: iOS ends an app that keeps an
    /// expired task. Whichever comes first ends it; the other does nothing.
    static func run<T: Sendable>(
        _ name: String, system: some BackgroundTaskSystem, _ body: () async throws -> T
    ) async rethrows -> T {
        let task = await BackgroundTask.begin(name, on: system)
        defer {
            Task { @MainActor in task.end() }
        }
        return try await body()
    }
}

/// The system's background tasks: UIKit's on iOS, a fake in tests. Called on
/// the main actor, where UIKit also calls `expiration`.
@MainActor
protocol BackgroundTaskSystem: Sendable {
    /// A task named `name`; `nil` when the app gets no background time.
    func begin(_ name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> Int?
    func end(_ id: Int)
}

/// One background task, ended once.
@MainActor
final class BackgroundTask {
    private let system: any BackgroundTaskSystem
    private var id: Int?

    private init(system: any BackgroundTaskSystem) {
        self.system = system
    }

    static func begin(_ name: String, on system: any BackgroundTaskSystem) -> BackgroundTask {
        let task = BackgroundTask(system: system)
        // The expiration runs on the main actor too, so not before `id` is set.
        task.id = system.begin(name) { [task] in
            Log.notice(.app, "background time ran out: \(name)")
            task.end()
        }
        return task
    }

    func end() {
        guard let id else { return }
        self.id = nil
        system.end(id)
    }
}

#if os(iOS)
/// `BackgroundTaskSystem` on `UIApplication`.
@MainActor
struct UIKitBackgroundTasks: BackgroundTaskSystem {
    func begin(_ name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ id: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
    }
}
#endif
