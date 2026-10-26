import Foundation

public enum TransportState: Equatable, Sendable {
    case closed
    case open
}

public enum TransportError: Error, Equatable, Sendable {
    case openFailed(path: String, errno: Int32)
    case configureFailed(errno: Int32)
    case notConnected
    case writeFailed(errno: Int32)
    case writeTimedOut
}

/// A line-oriented link to the Flipper (USB serial now, BLE in Phase 2).
public protocol Transport: AnyObject, Sendable {
    var state: TransportState { get }
    /// Decoded messages of the current connection, for a single consumer. The
    /// stream finishes when the connection drops; each `connect()` starts a new
    /// one. Lines that do not decode are dropped (PROTOCOL.md).
    var messages: AsyncStream<Message> { get }
    /// Opens the link; does nothing while it is open.
    func connect() throws
    /// Writes one newline-terminated line.
    func send(_ message: Message) throws
    func disconnect()
}
