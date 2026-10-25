import Foundation

/// Splits a byte stream into NDJSON lines.
///
/// Strips a "\r" before the "\n", skips empty lines and drops a line longer than
/// `maxLineBytes` (counting its "\n") whole, up to the next "\n".
public struct NDJSONFramer: Sendable {
    public let maxLineBytes: Int
    /// Over-long lines dropped so far.
    public private(set) var droppedLines = 0

    private var buffer: [UInt8] = []
    private var dropping = false

    public init(maxLineBytes: Int = Message.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Feeds received bytes; returns the lines completed by them, without terminators.
    public mutating func push(_ bytes: some Sequence<UInt8>) -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 0x0A {
                if !dropping {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    if !buffer.isEmpty { lines.append(Data(buffer)) }
                }
                buffer.removeAll(keepingCapacity: true)
                dropping = false
            } else if !dropping {
                buffer.append(byte)
                if buffer.count > maxLineBytes - 1 {
                    buffer.removeAll(keepingCapacity: true)
                    dropping = true
                    droppedLines += 1
                }
            }
        }
        return lines
    }

    /// Forgets a partial line, e.g. after the transport reconnects.
    public mutating func reset() {
        buffer.removeAll()
        dropping = false
    }
}
