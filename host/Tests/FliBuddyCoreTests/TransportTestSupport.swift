import Foundation
@testable import FliBuddyCore

import Darwin

/// Polls `condition` every 10 ms until it holds or `timeout` passes, on the
/// caller's actor (so `@MainActor` tests can poll view models).
func eventually(
    isolation: isolated (any Actor)? = #isolation, timeout: Duration = .seconds(2), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Drains an `AsyncStream` in the background so tests can wait on what arrived.
actor Collector<Element: Sendable> {
    private(set) var items: [Element] = []
    private(set) var finished = false
    private var task: Task<Void, Never>?

    init() {}

    static func draining(_ stream: AsyncStream<Element>) async -> Collector {
        let collector = Collector()
        await collector.start(stream)
        return collector
    }

    private func start(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await item in stream { await self?.append(item) }
            await self?.finish()
        }
    }

    private func append(_ item: Element) { items.append(item) }
    private func finish() { finished = true }
}

#if os(macOS)
/// An `openpty()` pair: the transport opens `slavePath` like a serial device,
/// the test plays the Flipper on `master`.
final class PseudoTerminal {
    let master: Int32
    let slavePath: String
    private var slave: Int32

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.master = master
        self.slave = slave
        slavePath = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Drops the test's own slave descriptor once the transport holds one.
    func closeSlave() {
        if slave >= 0 { close(slave) }
        slave = -1
    }

    func closeMaster() {
        close(master)
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(master, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 { offset += written } else if errno != EINTR { return }
            }
        }
    }

    /// Reads bytes from the master up to and including the next "\n".
    func readLine(timeout: Duration = .seconds(2)) -> Data? {
        var line = Data()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            var poller = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 20) > 0 else { continue }
            var byte: UInt8 = 0
            guard read(master, &byte, 1) == 1 else { return nil }
            line.append(byte)
            if byte == 0x0A { return line }
        }
        return nil
    }

    deinit {
        closeSlave()
    }
}
#endif

/// In-memory `Transport` for session tests.
final class FakeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Message>.Continuation?
    private var stream = AsyncStream<Message> { $0.finish() }
    private var _sent: [Message] = []
    private var _connectCount = 0
    var connectError: Error?
    /// Thrown by the next `send`, once.
    var nextSendError: Error?

    var state: TransportState {
        lock.withLock { continuation == nil ? .closed : .open }
    }

    var messages: AsyncStream<Message> {
        lock.withLock { stream }
    }

    var sent: [Message] {
        lock.withLock { _sent }
    }

    var connectCount: Int {
        lock.withLock { _connectCount }
    }

    func connect() throws {
        try lock.withLock {
            _connectCount += 1
            if let connectError { throw connectError }
            let (stream, continuation) = AsyncStream<Message>.makeStream()
            self.stream = stream
            self.continuation = continuation
        }
    }

    func send(_ message: Message) throws {
        try lock.withLock {
            guard continuation != nil else { throw TransportError.notConnected }
            if let error = nextSendError {
                nextSendError = nil
                throw error
            }
            _sent.append(message)
        }
    }

    func disconnect() {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    /// The Flipper sends a line.
    func deliver(_ message: Message) {
        _ = lock.withLock { continuation }?.yield(message)
    }
}

extension Message {
    static let flipperHello = Message.hello(Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1"))
    static let hostHello = Message.hello(Hello(app: "flibuddy-mac/0.1.0", os: "macOS 26.0"))
}
