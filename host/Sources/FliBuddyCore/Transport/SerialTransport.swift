import Foundation

#if os(macOS)
import Darwin

/// The Flipper's USB CDC port (`/dev/cu.usbmodemflip_*`) in raw mode, 115200 8N1.
///
/// Opening the port raises DTR, which makes the FAP send its `hello`.
public final class SerialTransport: Transport, @unchecked Sendable {
    public static let devicePrefix = "cu.usbmodemflip"
    /// How long `send` waits for room in the output buffer.
    static let writeTimeoutMs: Int32 = 1000

    public let path: String

    private let queue = DispatchQueue(label: "FliBuddy.SerialTransport")
    /// Guards `connection` and `stream`; held across a write so that the
    /// descriptor cannot be closed under it.
    private let lock = NSLock()
    private var connection: Connection?
    private var stream = AsyncStream<Message> { $0.finish() }

    public init(path: String) {
        self.path = path
    }

    deinit {
        connection?.source.cancel()
    }

    /// Flipper call-out devices in `directory`, sorted. `listing` is injectable for tests.
    public static func discoverFlipperPorts(
        in directory: String = "/dev",
        listing: (String) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0) }
    ) -> [String] {
        let names = (try? listing(directory)) ?? []
        return names.filter { $0.hasPrefix(devicePrefix) }.sorted().map { directory + "/" + $0 }
    }

    public var state: TransportState {
        lock.withLock { connection == nil ? .closed : .open }
    }

    public var messages: AsyncStream<Message> {
        lock.withLock { stream }
    }

    public func connect() throws {
        try lock.withLock {
            guard connection == nil else { return }
            // O_NONBLOCK keeps open() from waiting for carrier detect.
            let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else {
                let code = errno
                Log.error(.link, "open failed: port=\(path) errno=\(code) (\(String(cString: strerror(code))))")
                throw TransportError.openFailed(path: path, errno: code)
            }
            do {
                try Self.configure(fd)
            } catch {
                close(fd)
                Log.error(.link, "configure failed: port=\(path) error=\(Session.describe(error))")
                throw error
            }
            let (stream, continuation) = AsyncStream<Message>.makeStream()
            // Reading runs on `queue`, outside the task that connects: it
            // logs to the log in effect now.
            let connection = Connection(fd: fd, queue: queue, continuation: continuation, log: Log.router)
            // The handler keeps the connection alive until the source is
            // cancelled; dispatch releases it then, breaking the cycle.
            connection.source.setEventHandler { [weak self, connection] in
                self?.readAvailable(connection)
            }
            connection.source.resume()
            self.connection = connection
            self.stream = stream
            Log.info(.link, "open: port=\(path)")
        }
    }

    public func send(_ message: Message) throws {
        let line = try message.encodedLine()
        try lock.withLock {
            guard let connection else { throw TransportError.notConnected }
            do {
                try Self.write(line, to: connection.fd)
            } catch {
                Log.error(.link, "write failed: port=\(path) error=\(Session.describe(error))")
                throw error
            }
            WireLog.sent(line)
        }
    }

    public func disconnect() {
        let connection = lock.withLock {
            defer { self.connection = nil }
            return self.connection
        }
        guard let connection else { return }
        Log.info(.link, "close: port=\(path)")
        connection.source.cancel()
    }

    // MARK: - Reading (on `queue`)

    private func readAvailable(_ connection: Connection) {
        Log.$scoped.withValue(connection.log) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(connection.fd, &buffer, buffer.count)
                if count > 0 {
                    for message in WireLog.receive(buffer[..<count], framer: &connection.framer) {
                        connection.continuation.yield(message)
                    }
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN {
                    return
                } else {
                    // EOF or an error such as ENXIO: the device went away.
                    let code = errno
                    let reason = count == 0 ? "end of file" : "errno=\(code) (\(String(cString: strerror(code))))"
                    hangUp(connection, reason: reason)
                    return
                }
            }
        }
    }

    private func hangUp(_ connection: Connection, reason: String) {
        let current = lock.withLock {
            defer { if self.connection === connection { self.connection = nil } }
            return self.connection === connection
        }
        if current { Log.notice(.link, "hangup: port=\(path) reason=\(reason)") }
        connection.source.cancel()
    }

    // MARK: - POSIX helpers

    static func configure(_ fd: Int32) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { throw TransportError.configureFailed(errno: errno) }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        // 8 data bits, no parity, 1 stop bit, no hardware flow control, ignore modem lines.
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        options.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw TransportError.configureFailed(errno: errno) }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&poller, 1, writeTimeoutMs)
                    if ready == 0 { throw TransportError.writeTimedOut }
                    if ready < 0, errno != EINTR { throw TransportError.writeFailed(errno: errno) }
                } else {
                    throw TransportError.writeFailed(errno: errno)
                }
            }
        }
    }
}

/// One open descriptor with its read source. The framer is touched only on the
/// source's queue; cancelling the source closes the descriptor and finishes the stream.
private final class Connection: @unchecked Sendable {
    let fd: Int32
    let source: DispatchSourceRead
    let continuation: AsyncStream<Message>.Continuation
    let log: LogRouter
    var framer = NDJSONFramer()

    init(fd: Int32, queue: DispatchQueue, continuation: AsyncStream<Message>.Continuation, log: LogRouter) {
        self.fd = fd
        self.continuation = continuation
        self.log = log
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler {
            close(fd)
            continuation.finish()
        }
    }
}
#else
/// Off macOS there is no USB serial port: no Flipper ports are found and
/// connecting fails, so a USB choice reports "not connected".
public final class SerialTransport: Transport, @unchecked Sendable {
    public static let devicePrefix = "cu.usbmodemflip"

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public static func discoverFlipperPorts() -> [String] { [] }

    public var state: TransportState { .closed }

    public var messages: AsyncStream<Message> { AsyncStream { $0.finish() } }

    public func connect() throws { throw TransportError.notConnected }

    public func send(_ message: Message) throws { throw TransportError.notConnected }

    public func disconnect() {}
}
#endif
