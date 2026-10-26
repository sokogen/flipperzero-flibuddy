import Foundation

/// The wire in the log: lines sent and received at `.debug`, cut to
/// `lineLimit` characters, and lines dropped because they do not decode at
/// `.error`. Lines of another protocol version are told once per connection
/// (`otherVersion`), then dropped at `.debug`. The transports call it where
/// lines are encoded and decoded.
enum WireLog {
    static let lineLimit = 300
    static let droppedLimit = 120

    /// An encoded line, as written to the transport.
    static func sent(_ line: Data) {
        Log.debug(.wire, "tx: \(excerpt(line, limit: lineLimit))")
    }

    /// Feeds received bytes to `framer`; returns the messages they complete.
    /// `otherVersion`: the connection's peer version other than ours, set by
    /// the first line in it.
    static func receive(
        _ bytes: some Sequence<UInt8>, framer: inout NDJSONFramer, otherVersion: inout Int?
    ) -> [Message] {
        let dropped = framer.droppedLines
        let lines = framer.push(bytes)
        for _ in dropped..<framer.droppedLines {
            Log.error(.wire, "dropped: reason=line too long, over \(framer.maxLineBytes) bytes")
        }
        return lines.compactMap { received($0, otherVersion: &otherVersion) }
    }

    /// The message of one line without its terminator; `nil` when it does
    /// not decode.
    static func received(_ line: Data, otherVersion: inout Int?) -> Message? {
        Log.debug(.wire, "rx: \(excerpt(line, limit: lineLimit))")
        do {
            return try Message.decode(line: line)
        } catch ProtocolError.unsupportedVersion(let version) {
            if otherVersion != version {
                otherVersion = version
                Log.error(.wire, versionMismatch(version))
            }
            Log.debug(.wire, "dropped: reason=unsupported version \(version) line=\(excerpt(line, limit: droppedLimit))")
            return nil
        } catch {
            Log.error(.wire, "dropped: reason=\(reason(error)) line=\(excerpt(line, limit: droppedLimit))")
            return nil
        }
    }

    static func received(_ line: Data) -> Message? {
        var otherVersion: Int?
        return received(line, otherVersion: &otherVersion)
    }

    /// "Flipper speaks protocol 1, host speaks 2".
    static func versionMismatch(_ version: Int) -> String {
        "Flipper speaks protocol \(version), host speaks \(Message.version)"
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
