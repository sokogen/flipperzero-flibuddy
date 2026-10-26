import Foundation

/// Byte-level flow over the SpoolBuddy GATT service: outgoing lines become RX
/// writes of at most `writeSize` bytes, one in flight at a time; TX
/// notifications are reassembled into messages.
///
/// Writes are cut from a single byte queue when they are handed out, so a
/// write may end one line and start the next, and a change of `writeSize`
/// applies from the next write on.
public struct BLEChunker: Sendable {
    /// The largest characteristic value the Flipper's service accepts.
    public static let maxWriteSize = 243
    /// ATT MTU 23 minus the 3-byte header, before an MTU exchange.
    public static let defaultWriteSize = 20

    /// The payload of one write, kept within `1...maxWriteSize`. Set it from
    /// `maximumWriteValueLength(for: .withoutResponse)`, which is ATT MTU - 3
    /// (the with-response value is the 512-byte limit of long writes).
    public var writeSize: Int {
        didSet { writeSize = Self.clamp(writeSize) }
    }

    private var pending: [UInt8] = []
    private var inFlight = false
    private var framer = NDJSONFramer()

    public init(writeSize: Int = defaultWriteSize) {
        self.writeSize = Self.clamp(writeSize)
    }

    /// A write was handed out and is not confirmed yet.
    var isWriteInFlight: Bool { inFlight }

    /// Bytes are queued that have not been handed out yet.
    var hasPendingWrites: Bool { !pending.isEmpty }

    /// Queues one line, given without its terminator; "\n" is appended. An
    /// empty line queues nothing.
    mutating func enqueue(line: Data) throws {
        guard !line.isEmpty else { return }
        var terminated = line
        terminated.append(0x0A)
        try Message.checkLineLength(terminated)
        pending.append(contentsOf: terminated)
    }

    /// Queues the encoded line of a message.
    public mutating func enqueue(_ message: Message) throws {
        pending.append(contentsOf: try message.encodedLine())
    }

    /// The next write, or `nil` while one is in flight or nothing is queued.
    public mutating func nextWrite() -> Data? {
        guard !inFlight, !pending.isEmpty else { return nil }
        let count = min(writeSize, pending.count)
        let write = Data(pending[..<count])
        pending.removeFirst(count)
        inFlight = true
        return write
    }

    /// The peripheral confirmed the write in flight; the next one may go out.
    public mutating func writeConfirmed() {
        inFlight = false
    }

    /// Feeds one TX notification; returns the messages it completes. Lines
    /// that do not decode or exceed the protocol limit are dropped.
    public mutating func receive(_ notification: Data) -> [Message] {
        framer.push(notification).compactMap { try? Message.decode(line: $0) }
    }

    /// Forgets queued writes, the write in flight and a partial inbound line,
    /// e.g. when the connection drops. `writeSize` is kept.
    public mutating func reset() {
        pending.removeAll()
        inFlight = false
        framer.reset()
    }

    private static func clamp(_ size: Int) -> Int {
        min(max(size, 1), maxWriteSize)
    }
}
