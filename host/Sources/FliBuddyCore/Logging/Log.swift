import Foundation
import os

/// How much gets logged. A line reaches the sinks when its level is at or
/// above the router's level.
public enum LogLevel: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case debug, info, notice, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        }
    }

    /// `FLIBUDDY_LOG` (`debug`, `info`, `notice`, `error`, any case); `.info`
    /// when it is missing or unknown.
    public static func fromEnvironment(_ environment: [String: String]) -> LogLevel {
        let name = environment["FLIBUDDY_LOG"]?.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.description == name } ?? .info
    }
}

/// One event, already redacted.
public struct LogLine: Equatable, Sendable {
    public let date: Date
    public let level: LogLevel
    public let category: Log.Category
    public let message: String

    public init(date: Date, level: LogLevel, category: Log.Category, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    /// `2026-10-26T13:04:05.123+0300 INFO link message`, on one line: line
    /// breaks in the message are escaped.
    public func formatted(timeZone: TimeZone) -> String {
        formatted(using: LogLine.timestampFormatter(timeZone: timeZone))
    }

    func formatted(using formatter: DateFormatter) -> String {
        "\(formatter.string(from: date)) \(level.description.uppercased()) \(category.rawValue) \(Self.escaped(message))"
    }

    static func timestampFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }

    private static func escaped(_ message: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            switch scalar {
            case "\n": result.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": result.append(contentsOf: #"\r"#.unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }
}

/// Where log lines go: the unified log, a file, memory in tests.
public protocol LogSink: Sendable {
    func write(line: LogLine)
}

/// Filters by level, redacts and fans lines out to the sinks.
public final class LogRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLevel: LogLevel
    private var storedSinks: [any LogSink]

    public init(level: LogLevel, sinks: [any LogSink]) {
        storedLevel = level
        storedSinks = sinks
    }

    public var level: LogLevel {
        get { lock.withLock { storedLevel } }
        set { lock.withLock { storedLevel = newValue } }
    }

    public var sinks: [any LogSink] {
        get { lock.withLock { storedSinks } }
        set { lock.withLock { storedSinks = newValue } }
    }

    /// The message is only built when the level lets the line through.
    public func log(_ level: LogLevel, _ category: Log.Category, _ message: @autoclosure () -> String, date: Date = Date()) {
        let (threshold, sinks) = lock.withLock { (storedLevel, storedSinks) }
        guard level >= threshold, !sinks.isEmpty else { return }
        let line = LogLine(date: date, level: level, category: category, message: Log.redact(message()))
        for sink in sinks {
            sink.write(line: line)
        }
    }
}

/// The app-wide log: `Log.info(.link, "state: idle -> connecting")`.
public enum Log {
    public enum Category: String, CaseIterable, Sendable {
        case link, wire, session, bambuddy, settings, sync, ui, app
    }

    /// Until the app installs its sinks everything goes to the unified log.
    static let shared = LogRouter(
        level: .fromEnvironment(ProcessInfo.processInfo.environment),
        sinks: [OSLogSink()]
    )

    /// Replaces `shared` within a task, so tests capture lines without
    /// touching the process-wide log.
    @TaskLocal static var scoped: LogRouter?

    static var router: LogRouter { scoped ?? shared }

    public static var level: LogLevel {
        get { router.level }
        set { router.level = newValue }
    }

    public static var sinks: [any LogSink] {
        get { router.sinks }
        set { router.sinks = newValue }
    }

    public static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        router.log(.debug, category, message())
    }

    public static func info(_ category: Category, _ message: @autoclosure () -> String) {
        router.log(.info, category, message())
    }

    public static func notice(_ category: Category, _ message: @autoclosure () -> String) {
        router.log(.notice, category, message())
    }

    public static func error(_ category: Category, _ message: @autoclosure () -> String) {
        router.log(.error, category, message())
    }

    private static let redacted = "«redacted»"

    /// `key=…`, `X-API-Key: …`, `"apiKey":"…"` and the like, except the
    /// `key=present|absent` that settings lines use.
    private static let keyValue = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_-])((?:x-api-key|api[_-]?key|key)"?\s*[=:]\s*"?)(?!(?:present|absent)(?:[\s&"',;]|$))[^\s&"',;]+"#,
        options: [.caseInsensitive]
    )

    /// A Bambuddy API key anywhere in the text.
    private static let bambuddyKey = try! NSRegularExpression(pattern: #"\bbb_[A-Za-z0-9_\-.~%+/]+"#)

    /// The message with every API key replaced by `«redacted»`.
    public static func redact(_ message: String) -> String {
        var result = message
        result = keyValue.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1\(redacted)"
        )
        result = bambuddyKey.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: redacted
        )
        return result
    }
}

/// The unified log, subsystem `com.sokolachko.flibuddy`, one category per
/// `Log.Category`. Lines are redacted before they get here, so they are
/// logged as public.
public struct OSLogSink: LogSink {
    public static let subsystem = "com.sokolachko.flibuddy"

    private let loggers: [Log.Category: Logger]

    public init() {
        loggers = Dictionary(uniqueKeysWithValues: Log.Category.allCases.map {
            ($0, Logger(subsystem: Self.subsystem, category: $0.rawValue))
        })
    }

    public func write(line: LogLine) {
        guard let logger = loggers[line.category] else { return }
        let type: OSLogType = switch line.level {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        }
        logger.log(level: type, "\(line.message, privacy: .public)")
    }
}

/// A plain text log that `tail -f` can follow. Appends one line per event,
/// rotates to `flibuddy.log.1`, `.2`, … at `maxBytes`, keeping `keptFiles`
/// old files. A write failure is reported once and then ignored.
public final class FileSink: LogSink, @unchecked Sendable {
    public static let defaultMaxBytes = 5 * 1024 * 1024
    public static let defaultKeptFiles = 3

    /// `~/Library/Logs/FliBuddy/flibuddy.log` on macOS; on iOS and watchOS
    /// `Logs/flibuddy.log` in the app's Application Support.
    public static var defaultURL: URL {
        let fileManager = FileManager.default
        #if os(macOS)
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/FliBuddy/flibuddy.log")
        #else
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Logs/flibuddy.log")
        #endif
    }

    public let url: URL
    private let maxBytes: Int
    private let keptFiles: Int
    private let formatter: DateFormatter
    private let onFailure: @Sendable (String) -> Void

    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private var reportedFailure = false

    public init(
        url: URL = FileSink.defaultURL,
        maxBytes: Int = FileSink.defaultMaxBytes,
        keptFiles: Int = FileSink.defaultKeptFiles,
        timeZone: TimeZone = .current,
        onFailure: @escaping @Sendable (String) -> Void = FileSink.reportThroughUnifiedLog
    ) {
        self.url = url
        self.maxBytes = maxBytes
        self.keptFiles = keptFiles
        self.formatter = LogLine.timestampFormatter(timeZone: timeZone)
        self.onFailure = onFailure
    }

    deinit {
        try? handle?.close()
    }

    public func write(line: LogLine) {
        lock.withLock {
            let data = Data((line.formatted(using: formatter) + "\n").utf8)
            do {
                var file = try openFile()
                if size > 0, size + data.count > maxBytes {
                    try rotate()
                    file = try openFile()
                }
                try file.write(contentsOf: data)
                size += data.count
            } catch {
                try? handle?.close()
                handle = nil
                if !reportedFailure {
                    reportedFailure = true
                    onFailure("log file \(url.path) cannot be written: \(error.localizedDescription)")
                }
            }
        }
    }

    private func openFile() throws -> FileHandle {
        if let handle { return handle }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path), !fileManager.createFile(atPath: url.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let file = try FileHandle(forWritingTo: url)
        size = Int(try file.seekToEnd())
        handle = file
        return file
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        size = 0
        let fileManager = FileManager.default
        guard keptFiles > 0 else {
            try fileManager.removeItem(at: url)
            return
        }
        try? fileManager.removeItem(at: old(keptFiles))
        for n in stride(from: keptFiles - 1, through: 1, by: -1) where fileManager.fileExists(atPath: old(n).path) {
            try fileManager.moveItem(at: old(n), to: old(n + 1))
        }
        try fileManager.moveItem(at: url, to: old(1))
    }

    private func old(_ n: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(n)")
    }

    public static let reportThroughUnifiedLog: @Sendable (String) -> Void = { message in
        Logger(subsystem: OSLogSink.subsystem, category: Log.Category.app.rawValue)
            .error("\(message, privacy: .public)")
    }
}

/// Keeps lines in memory, for tests.
public final class MemorySink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogLine] = []

    public init() {}

    public func write(line: LogLine) {
        lock.withLock { stored.append(line) }
    }

    public var lines: [LogLine] { lock.withLock { stored } }

    /// `<category> <message>` per line, the form the tests compare.
    public var events: [String] { lines.map { "\($0.category.rawValue) \($0.message)" } }
}
