import Foundation
@testable import FliBuddyCore

/// Runs `body` with the log going to a fresh memory sink at `level` and
/// returns the sink. Tasks started inside inherit the log; work on dispatch
/// queues does not, unless the code under test captured it.
nonisolated(nonsending) func capturingLog(
    level: LogLevel = .info, _ body: nonisolated(nonsending) () async throws -> Void
) async rethrows -> MemorySink {
    let sink = MemorySink()
    try await Log.$scoped.withValue(LogRouter(level: level, sinks: [sink]), operation: body)
    return sink
}

extension MemorySink {
    /// The events that start with `prefix`, e.g. `"link state:"`.
    func events(_ prefix: String) -> [String] {
        events.filter { $0.hasPrefix(prefix) }
    }
}
