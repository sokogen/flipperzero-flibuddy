import Foundation

/// The wire in the log: lines sent and received at `.debug`, cut to
/// `lineLimit` characters, and lines dropped because they do not decode at
/// `.error`. The transports call it where lines are encoded and decoded.
enum WireLog {
    static let lineLimit = 300
    static let droppedLimit = 120

    /// An encoded line, as written to the transport.
    static func sent(_ line: Data) {
        Log.debug(.wire, "tx: \(excerpt(line, limit: lineLimit))")
    }

    /// Feeds received bytes to `framer`; returns the messages they complete.
    static func receive(_ bytes: some Sequence<UInt8>, framer: inout NDJSONFramer) -> [Message] {
        let dropped = framer.droppedLines
        let lines = framer.push(bytes)
        for _ in dropped..<framer.droppedLines {
            Log.error(.wire, "dropped: reason=line too long, over \(framer.maxLineBytes) bytes")
        }
        return lines.compactMap(received)
    }

    /// The message of one line without its terminator; `nil` when it does
    /// not decode.
    static func received(_ line: Data) -> Message? {
        Log.debug(.wire, "rx: \(excerpt(line, limit: lineLimit))")
        do {
            return try Message.decode(line: line)
        } catch {
            Log.error(.wire, "dropped: reason=\(reason(error)) line=\(excerpt(line, limit: droppedLimit))")
            return nil
        }
    }

    /// The line as text without its terminator, cut after `limit`
    /// characters with the bytes left out counted: `… (+N bytes)`.
    static func excerpt(_ line: Data, limit: Int) -> String {
        var text = String(decoding: line, as: UTF8.self)
        while text.last?.isNewline == true { text.removeLast() }
        guard text.count > limit else { return text }
        let kept = text.prefix(limit)
        return "\(kept)… (+\(text.utf8.count - kept.utf8.count) bytes)"
    }

    static func reason(_ error: any Error) -> String {
        switch error as? ProtocolError {
        case .unknownType(let type): "unknown type \(type)"
        case .unsupportedVersion(let version): "unsupported version \(version)"
        case .malformed(let detail): "malformed: \(detail)"
        case .invalid(let field): "invalid \(field)"
        case .lineTooLong(let bytes): "line too long, \(bytes) bytes"
        case nil: String(describing: error)
        }
    }
}

extension Duration {
    /// `2s`, or `50ms` when not a whole number of seconds.
    var logDescription: String {
        let (seconds, attoseconds) = components
        if attoseconds == 0 { return "\(seconds)s" }
        return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000)ms"
    }
}
