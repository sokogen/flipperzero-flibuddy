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
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case peripheralNotFound
    /// A Flipper was found but did not connect or open its service in time.
    case connectTimedOut
    case serviceNotFound
}

/// A line-oriented link to the Flipper: USB serial or Bluetooth LE.
public protocol Transport: AnyObject, Sendable {
    var state: TransportState { get }
    /// Decoded messages of the current connection, for a single consumer. The
    /// stream finishes when the connection drops; each `connect()` starts a new
    /// one. Lines that do not decode are dropped (PROTOCOL.md).
    var messages: AsyncStream<Message> { get }
    /// The protocol version the peer's lines on the current connection
    /// carry, when it is not `Message.version` (those lines are dropped).
    var peerVersion: Int? { get }
    /// Opens the link; does nothing while it is open.
    func connect() async throws
    /// Writes one newline-terminated line.
    func send(_ message: Message) throws
    func disconnect()
}

extension Transport {
    public var peerVersion: Int? { nil }
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code): "Cannot open \(path): \(String(cString: strerror(code)))"
        case .configureFailed(let code): "Cannot set up the serial port: \(String(cString: strerror(code)))"
        case .notConnected: "The Flipper is not connected"
        case .writeFailed(let code): "Writing to the Flipper failed: \(String(cString: strerror(code)))"
        case .writeTimedOut: "Writing to the Flipper timed out"
        case .bluetoothOff: "Bluetooth is off"
        case .bluetoothUnauthorized: "FliBuddy is not allowed to use Bluetooth"
        case .bluetoothUnsupported: "This device has no Bluetooth LE"
        case .peripheralNotFound: "No Flipper found over Bluetooth"
        case .connectTimedOut: "Flipper did not answer"
        case .serviceNotFound: "The Flipper does not offer FliBuddy over Bluetooth; choose Bluetooth in the Flipper app"
        }
    }
}
