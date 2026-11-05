import Foundation
import Testing
@testable import FliBuddyCore

/// Background tasks as UIKit hands them out, recorded.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskSystem {
    /// `begin` answers no task (the app has no background time left).
    var refuses = false
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []
    private var expirations: [Int: @MainActor @Sendable () -> Void] = [:]

    func begin(_ name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> Int? {
        guard !refuses else { return nil }
        begun.append(name)
        expirations[begun.count] = expiration
        return begun.count
    }

    func end(_ id: Int) {
        ended.append(id)
    }

    /// The system's time for task `id` runs out.
    func expire(_ id: Int) {
        expirations[id]?()
    }
}

@Suite("BackgroundActivity")
struct BackgroundActivityTests {
    @Test func theTaskEndsWhenTheWorkEnds() async {
        let system = await FakeBackgroundTasks()

        let answer = await BackgroundActivity.run("Bambuddy GET /x", system: system) { 42 }

        #expect(answer == 42)
        #expect(await system.begun == ["Bambuddy GET /x"])
        #expect(await eventually { await system.ended == [1] })
    }

    @Test func expiringEndsTheTaskAtOnceAndOnlyOnce() async throws {
        let system = await FakeBackgroundTasks()

        let sink = await capturingLog {
            await BackgroundActivity.run("Bambuddy PATCH /y", system: system) {
                await system.expire(1)
                // Ended by the expiration, before the work is done.
                #expect(await system.ended == [1])
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await system.ended == [1])
        #expect(sink.events("app background time ran out") == ["app background time ran out: Bambuddy PATCH /y"])
    }

    @Test func withoutBackgroundTimeNothingIsEnded() async throws {
        let system = await FakeBackgroundTasks()
        await MainActor.run { system.refuses = true }

        await BackgroundActivity.run("Bambuddy GET /z", system: system) {}

        try await Task.sleep(for: .milliseconds(50))
        #expect(await system.ended.isEmpty)
    }

    @Test func workThatThrowsStillEndsTheTask() async {
        let system = await FakeBackgroundTasks()

        await #expect(throws: BambuddyError.network("x")) {
            try await BackgroundActivity.run("Bambuddy GET /w", system: system) { throw BambuddyError.network("x") }
        }

        #expect(await eventually { await system.ended == [1] })
    }
}
