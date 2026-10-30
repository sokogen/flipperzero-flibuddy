import Foundation
import Testing
@testable import FliBuddyCore

@Suite struct LogTests {
    /// 2026-10-26T10:04:05.250Z, 13:04:05.250 in Moscow.
    private static let date = Date(timeIntervalSince1970: 1_793_009_045.25)
    private static let moscow = TimeZone(secondsFromGMT: 3 * 3600)!

    @Test func anInfoLineReachesTheSinkWithItsTimestampLevelCategoryAndMessage() {
        let sink = MemorySink()
        let router = LogRouter(level: .info, sinks: [sink])

        router.log(.info, .link, "connect: transport=usb", date: Self.date)

        #expect(sink.lines == [LogLine(date: Self.date, level: .info, category: .link, message: "connect: transport=usb")])
        #expect(sink.events == ["link connect: transport=usb"])
    }

    @Test func linesBelowTheLevelAreDroppedWithoutFormattingTheMessage() {
        let sink = MemorySink()
        let router = LogRouter(level: .info, sinks: [sink])
        var formatted = false

        router.log(.debug, .wire, { formatted = true; return "tx: {}" }())
        router.log(.error, .wire, "dropped: bad json")

        #expect(!formatted)
        #expect(sink.events == ["wire dropped: bad json"])

        router.level = .debug
        router.log(.debug, .wire, "tx: {}")
        #expect(sink.events == ["wire dropped: bad json", "wire tx: {}"])

        router.level = .error
        router.log(.notice, .app, "start")
        router.log(.info, .app, "start")
        #expect(sink.events.count == 2)
    }

    @Test func theStaticFacadeWritesToTheScopedRouter() {
        let sink = MemorySink()
        Log.$scoped.withValue(LogRouter(level: .debug, sinks: [sink])) {
            Log.debug(.wire, "tx: a")
            Log.info(.link, "state: idle -> connecting")
            Log.notice(.app, "start")
            Log.error(.bambuddy, "GET /x failed")
            #expect(Log.level == .debug)
            Log.level = .info
            Log.debug(.wire, "tx: b")
            #expect(Log.sinks.count == 1)
        }
        #expect(sink.lines.map(\.level) == [.debug, .info, .notice, .error])
        #expect(sink.events == ["wire tx: a", "link state: idle -> connecting", "app start", "bambuddy GET /x failed"])
    }

    @Test func theLevelComesFromTheEnvironment() {
        #expect(LogLevel.fromEnvironment([:]) == .info)
        #expect(LogLevel.fromEnvironment(["FLIBUDDY_LOG": "debug"]) == .debug)
        #expect(LogLevel.fromEnvironment(["FLIBUDDY_LOG": "INFO"]) == .info)
        #expect(LogLevel.fromEnvironment(["FLIBUDDY_LOG": " notice "]) == .notice)
        #expect(LogLevel.fromEnvironment(["FLIBUDDY_LOG": "error"]) == .error)
        #expect(LogLevel.fromEnvironment(["FLIBUDDY_LOG": "loud"]) == .info)
        #expect(LogLevel.debug < .info && LogLevel.info < .notice && LogLevel.notice < .error)
        #expect(LogLevel.allCases.map(\.description) == ["debug", "info", "notice", "error"])
    }

    @Test func everyCategoryHasItsName() {
        #expect(Log.Category.allCases.map(\.rawValue) == ["link", "wire", "session", "bambuddy", "settings", "sync", "ui", "app"])
    }

    @Test(arguments: [
        ("api key bb_abc123 saved", "api key «redacted» saved"),
        ("bambuddy://config?v=1&url=http%3A%2F%2Fnas%3A8000&key=bb_abc%2B1", "bambuddy://config?v=1&url=http%3A%2F%2Fnas%3A8000&key=«redacted»"),
        ("config?key=s3cret&v=1", "config?key=«redacted»&v=1"),
        ("X-API-Key: s3cret", "X-API-Key: «redacted»"),
        ("headers x-api-key=s3cret accept=json", "headers x-api-key=«redacted» accept=json"),
        (#"{"apiKey":"s3cret","coreWeight":242}"#, #"{"apiKey":"«redacted»","coreWeight":242}"#),
        ("load: url=http://nas:8000 key=present catalog=3", "load: url=http://nas:8000 key=present catalog=3"),
        ("load: key=absent", "load: key=absent"),
        ("monkey=3 turkey: 4", "monkey=3 turkey: 4"),
        ("test connection: url=http://admin:pa55@nas:8000", "test connection: url=http://«redacted»@nas:8000"),
        ("load: url=https://token@nas.local/bambuddy key=present", "load: url=https://«redacted»@nas.local/bambuddy key=present"),
        ("nothing secret here", "nothing secret here"),
    ])
    func redactionHidesAPIKeys(input: String, expected: String) {
        #expect(Log.redact(input) == expected)
    }

    @Test func messagesAreRedactedBeforeTheyReachTheSinks() {
        let sink = MemorySink()
        let router = LogRouter(level: .info, sinks: [sink])

        router.log(.info, .settings, "save: key=bb_secret")

        #expect(sink.events == ["settings save: key=«redacted»"])
    }

    @Test func aFileLineHasTheISOTimestampWithMillisecondsAndTheLocalOffset() {
        let line = LogLine(date: Self.date, level: .info, category: .link, message: "connect: transport=usb")
        #expect(line.formatted(timeZone: Self.moscow) == "2026-10-26T13:04:05.250+0300 INFO link connect: transport=usb")
        let utc = LogLine(date: Self.date, level: .error, category: .wire, message: "a\nb\r\nc")
        #expect(utc.formatted(timeZone: TimeZone(identifier: "UTC")!) == "2026-10-26T10:04:05.250+0000 ERROR wire a\\nb\\r\\nc")
    }

    @Test func theFileSinkAppendsOneLinePerEvent() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Logs/flibuddy.log")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "earlier\n".write(to: url, atomically: true, encoding: .utf8)
        let sink = FileSink(url: url, timeZone: Self.moscow)

        sink.write(line: LogLine(date: Self.date, level: .info, category: .link, message: "one"))
        // Flushed per line: readable before the sink goes away.
        #expect(try String(contentsOf: url, encoding: .utf8) == "earlier\n2026-10-26T13:04:05.250+0300 INFO link one\n")
        sink.write(line: LogLine(date: Self.date, level: .notice, category: .app, message: "two"))

        #expect(try String(contentsOf: url, encoding: .utf8) == """
        earlier
        2026-10-26T13:04:05.250+0300 INFO link one
        2026-10-26T13:04:05.250+0300 NOTICE app two

        """)
    }

    @Test func theFileSinkCreatesItsDirectory() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Library/Logs/FliBuddy/flibuddy.log")
        let sink = FileSink(url: url, timeZone: Self.moscow)

        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "start"))

        #expect(try String(contentsOf: url, encoding: .utf8) == "2026-10-26T13:04:05.250+0300 INFO app start\n")
    }

    @Test func theFileSinkRotatesAtTheSizeLimitAndKeepsTheConfiguredNumberOfOldFiles() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("flibuddy.log")
        // Each line is 44 bytes: two fit under 100, the third starts a new file.
        let sink = FileSink(url: url, maxBytes: 100, keptFiles: 2, timeZone: Self.moscow)
        func write(_ message: String) {
            sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: message))
        }
        func content(_ name: String) throws -> [String] {
            try String(contentsOf: directory.url.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").map { String($0.suffix(5)) }
        }

        for n in 1...8 { write("line\(n)") }

        #expect(try content("flibuddy.log") == ["line7", "line8"])
        #expect(try content("flibuddy.log.1") == ["line5", "line6"])
        #expect(try content("flibuddy.log.2") == ["line3", "line4"])
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("flibuddy.log.3").path))
    }

    @Test func aLineLargerThanTheLimitStillGetsWritten() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("flibuddy.log")
        let sink = FileSink(url: url, maxBytes: 10, keptFiles: 1, timeZone: Self.moscow)

        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "first"))
        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "second"))

        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix(" app second\n"))
        #expect(try String(contentsOf: directory.url.appendingPathComponent("flibuddy.log.1"), encoding: .utf8).hasSuffix(" app first\n"))
    }

    @Test func withNoOldFilesKeptRotationStartsAnEmptyFile() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("flibuddy.log")
        let sink = FileSink(url: url, maxBytes: 10, keptFiles: 0, timeZone: Self.moscow)

        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "first"))
        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "second"))

        #expect(try String(contentsOf: url, encoding: .utf8) == "2026-10-26T13:04:05.250+0300 INFO app second\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["flibuddy.log"])
    }

    @Test func aWriteFailureIsReportedOnceAndThenIgnored() throws {
        let directory = try TemporaryDirectory()
        // A file where the log directory should be: the directory cannot be created.
        let blocker = directory.url.appendingPathComponent("Logs")
        try "".write(to: blocker, atomically: true, encoding: .utf8)
        let failures = Failures()
        let sink = FileSink(url: blocker.appendingPathComponent("flibuddy.log"), onFailure: { failures.append($0) })

        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "one"))
        sink.write(line: LogLine(date: Self.date, level: .info, category: .app, message: "two"))

        #expect(failures.messages.count == 1)
        #expect(failures.messages.first?.contains("flibuddy.log") == true)
    }

    @Test func theDefaultFileLivesInTheLogsDirectory() {
        let path = FileSink.defaultURL.path
        #if os(macOS)
        #expect(path.hasSuffix("/Library/Logs/FliBuddy/flibuddy.log"))
        #else
        #expect(path.hasSuffix("/Application Support/Logs/flibuddy.log"))
        #endif
        #expect(FileSink.defaultMaxBytes == 5 * 1024 * 1024)
        #expect(FileSink.defaultKeptFiles == 3)
    }

    @Test func theUnifiedLogSinkAcceptsEveryLevel() {
        let sink = OSLogSink()
        #expect(OSLogSink.subsystem == "com.sokolachko.flibuddy")
        for level in LogLevel.allCases {
            sink.write(line: LogLine(date: Self.date, level: level, category: .ui, message: "log test \(level)"))
        }
    }

    @Test @MainActor func bootstrapInstallsTheSinksOnceAndLogsTheStartLine() {
        let sink = MemorySink()
        let file = URL(fileURLWithPath: "/tmp/FliBuddy/flibuddy.log")
        Log.$scoped.withValue(LogRouter(level: .error, sinks: [])) {
            #expect(Log.fileURL == nil)
            var madeFor: [URL] = []

            let first = Log.bootstrap(
                appName: "FliBuddy", version: "1.2.3", platform: "macOS 26.0", level: .debug, fileURL: file,
                makeSinks: { madeFor.append($0); return [sink] }
            )
            let second = Log.bootstrap(
                appName: "Other", version: "9.9.9", platform: "iOS 26.0", level: .error,
                fileURL: URL(fileURLWithPath: "/tmp/other.log"),
                makeSinks: { madeFor.append($0); return [MemorySink()] }
            )

            #expect(first)
            #expect(!second)
            #expect(madeFor == [file])
            #expect(Log.level == .debug)
            #expect(Log.fileURL == file)
            #expect(Log.sinks.count == 1)
        }
        #expect(sink.lines.map(\.level) == [.notice])
        #expect(sink.events == ["app start: FliBuddy 1.2.3 macOS 26.0 log=/tmp/FliBuddy/flibuddy.log level=debug"])
    }

    @Test @MainActor func theStartLineIsWrittenWhateverTheLevel() {
        let sink = MemorySink()
        Log.$scoped.withValue(LogRouter(level: .info, sinks: [])) {
            Log.bootstrap(
                appName: "FliBuddy", version: "1.2.3", platform: "macOS 26.0", level: .error,
                fileURL: URL(fileURLWithPath: "/tmp/FliBuddy/flibuddy.log"), makeSinks: { _ in [sink] }
            )
            Log.notice(.app, "filtered")
        }
        #expect(sink.events == ["app start: FliBuddy 1.2.3 macOS 26.0 log=/tmp/FliBuddy/flibuddy.log level=error"])
    }

    @Test @MainActor func bootstrapByDefaultWritesToTheUnifiedLogAndTheFile() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("Logs/flibuddy.log")
        try Log.$scoped.withValue(LogRouter(level: .info, sinks: [])) {
            #expect(Log.bootstrap(appName: "FliBuddy", level: .info, fileURL: file))

            let sinks = Log.sinks
            #expect(sinks.count == 2)
            #expect(sinks.first is OSLogSink)
            #expect((sinks.last as? FileSink)?.url == file)
            let content = try String(contentsOf: file, encoding: .utf8)
            #expect(content.hasSuffix(
                " NOTICE app start: FliBuddy \(FliBuddyCore.version) \(PlatformInfo.current) log=\(file.path) level=info\n"
            ))
        }
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ message: String) { lock.withLock { stored.append(message) } }
    var messages: [String] { lock.withLock { stored } }
}

/// A fresh directory under the temporary directory, removed on deinit.
private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("LogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
