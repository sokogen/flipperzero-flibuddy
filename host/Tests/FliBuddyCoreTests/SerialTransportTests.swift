import Darwin
import Foundation
import Testing
@testable import FliBuddyCore

#if os(macOS)

/// The transport opens the pty slave like `/dev/cu.usbmodemflip_*`; the test plays
/// the Flipper on the master.
@Suite(.serialized) struct SerialTransportTests {
    private func connected() throws -> (PseudoTerminal, SerialTransport) {
        let pty = try PseudoTerminal()
        let transport = SerialTransport(path: pty.slavePath)
        try transport.connect()
        pty.closeSlave()
        return (pty, transport)
    }

    @Test func linesFromTheFlipperArriveAsFramedMessages() async throws {
        let (pty, transport) = try connected()
        defer { transport.disconnect() }
        let received = await Collector.draining(transport.messages)
        let scan = try Message.decode(line: Fixtures.message("scan_mfc"))

        pty.write(#"{"t":"hello","v":1,"app":"flibuddy-fap/0.1.0","#)
        pty.write("\"fw\":\"1.5.1\"}\r\n")
        pty.write(try scan.encodedLine())

        #expect(await eventually { await received.items.count == 2 })
        #expect(await received.items == [.flipperHello, scan])
    }

    @Test func dropsBadLinesAndKeepsReading() async throws {
        let (pty, transport) = try connected()
        defer { transport.disconnect() }
        let received = await Collector.draining(transport.messages)

        pty.write("not json\n")
        pty.write(#"{"t":"ping","v":1}"# + "\n")
        pty.write(#"{"t":"hello","v":2,"app":"x","fw":"1"}"# + "\n")
        pty.write(String(repeating: "x", count: Message.maxLineBytes) + "\n")
        pty.write(try Message.flipperHello.encodedLine())

        #expect(await eventually { await received.items.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await received.items == [.flipperHello])
    }

    @Test func sendWritesOneNewlineTerminatedLine() throws {
        let (pty, transport) = try connected()
        defer { transport.disconnect() }

        try transport.send(.hostHello)

        // Raw mode: no echo of our own bytes and no "\n" -> "\r\n" translation.
        let line = try #require(pty.readLine())
        #expect(line == (try Message.hostHello.encodedLine()))
        #expect(line.last == 0x0A)
        #expect(!line.dropLast().contains(0x0A))
    }

    @Test func rawModeDoesNotEchoTheFlipperLines() async throws {
        let (pty, transport) = try connected()
        defer { transport.disconnect() }
        let received = await Collector.draining(transport.messages)

        pty.write(try Message.flipperHello.encodedLine())
        #expect(await eventually { await received.items.count == 1 })
        #expect(pty.readLine(timeout: .milliseconds(100)) == nil)
    }

    @Test func closingTheFlipperEndReportsDisconnect() async throws {
        let (pty, transport) = try connected()
        let received = await Collector.draining(transport.messages)
        #expect(transport.state == .open)

        pty.closeMaster()

        #expect(await eventually { await received.finished })
        #expect(transport.state == .closed)
        #expect(throws: TransportError.notConnected) { try transport.send(.hostHello) }
    }

    @Test func disconnectFinishesTheStreamAndCanReconnect() async throws {
        let pty = try PseudoTerminal()
        defer { pty.closeMaster() }
        let transport = SerialTransport(path: pty.slavePath)
        try transport.connect()
        let first = await Collector.draining(transport.messages)

        transport.disconnect()
        #expect(await eventually { await first.finished })
        #expect(transport.state == .closed)

        try transport.connect()
        defer { transport.disconnect() }
        pty.closeSlave()
        let second = await Collector.draining(transport.messages)
        pty.write(try Message.flipperHello.encodedLine())
        #expect(await eventually { await second.items == [.flipperHello] })
    }

    @Test func connectIsIdempotentWhileOpen() throws {
        let (pty, transport) = try connected()
        defer { transport.disconnect() }
        try transport.connect()
        try transport.send(.hostHello)
        #expect(pty.readLine() == (try Message.hostHello.encodedLine()))
    }

    @Test func connectToAMissingDeviceThrows() {
        let transport = SerialTransport(path: "/dev/cu.usbmodemflip_nope")
        #expect(throws: TransportError.openFailed(path: "/dev/cu.usbmodemflip_nope", errno: ENOENT)) {
            try transport.connect()
        }
        #expect(transport.state == .closed)
    }

    @Test func openingAndClosingAreLogged() async throws {
        let pty = try PseudoTerminal()
        defer { pty.closeMaster() }
        let transport = SerialTransport(path: pty.slavePath)

        let sink = try await capturingLog {
            try transport.connect()
            transport.disconnect()
            transport.disconnect()
        }

        #expect(sink.events == ["link open: port=\(pty.slavePath)", "link close: port=\(pty.slavePath)"])
    }

    @Test func aFailedOpenIsLoggedWithTheErrno() async {
        let transport = SerialTransport(path: "/dev/cu.usbmodemflip_nope")

        let sink = await capturingLog { _ = try? transport.connect() }

        #expect(sink.events == ["link open failed: port=/dev/cu.usbmodemflip_nope errno=2 (No such file or directory)"])
        #expect(sink.lines.map(\.level) == [.error])
    }

    @Test func wireLinesAndTheHangUpGoToTheLogInEffectAtConnect() async throws {
        let pty = try PseudoTerminal()
        let transport = SerialTransport(path: pty.slavePath)
        let hello = String(decoding: try Message.flipperHello.encodedLine().dropLast(), as: UTF8.self)

        let sink = try await capturingLog(level: .debug) {
            try transport.connect()
            pty.closeSlave()
            let received = await Collector.draining(transport.messages)
            try transport.send(.hostHello)
            pty.write(#"{"t":"ping","v":1}"# + "\n")
            pty.write(hello + "\n")
            #expect(await eventually { await received.items == [.flipperHello] })
            pty.closeMaster()
            #expect(await eventually { await received.finished })
        }

        let events = sink.events
        #expect(events.count == 6)
        #expect(Array(events.prefix(5)) == [
            "link open: port=\(pty.slavePath)",
            #"wire tx: {"app":"flibuddy-mac/0.1.0","os":"macOS 26.0","t":"hello","v":1}"#,
            #"wire rx: {"t":"ping","v":1}"#,
            #"wire dropped: reason=unknown type ping line={"t":"ping","v":1}"#,
            "wire rx: \(hello)",
        ])
        #expect(events.last?.hasPrefix("link hangup: port=\(pty.slavePath) reason=") == true)
    }

    @Test func sendBeforeConnectThrows() {
        let transport = SerialTransport(path: "/dev/null")
        #expect(throws: TransportError.notConnected) { try transport.send(.hostHello) }
    }

    @Test func messagesBeforeConnectIsAFinishedStream() async {
        let transport = SerialTransport(path: "/dev/null")
        let received = await Collector.draining(transport.messages)
        #expect(await eventually { await received.finished })
    }

    @Test func discoverFlipperPortsFiltersTheListing() {
        let listing = [
            "tty.usbmodemflip_Anen1", "cu.usbmodemflip_Anen1", "cu.Bluetooth-Incoming-Port",
            "cu.usbmodem1101", "cu.usbmodemflip_Bfoo3", "null",
        ]
        var asked: [String] = []
        let ports = SerialTransport.discoverFlipperPorts(in: "/dev") { directory in
            asked.append(directory)
            return listing
        }
        #expect(asked == ["/dev"])
        #expect(ports == ["/dev/cu.usbmodemflip_Anen1", "/dev/cu.usbmodemflip_Bfoo3"])
    }

    @Test func discoverFlipperPortsSurvivesAnUnreadableDirectory() {
        struct Unreadable: Error {}
        #expect(SerialTransport.discoverFlipperPorts(in: "/nope") { _ in throw Unreadable() }.isEmpty)
    }

    @Test func discoverFlipperPortsReadsTheRealDirectoryByDefault() {
        // Whatever is plugged in, every result is a Flipper call-out device.
        #expect(SerialTransport.discoverFlipperPorts().allSatisfy { $0.hasPrefix("/dev/cu.usbmodemflip") })
    }
}

#else
// Off macOS the transport is a stub: no ports, and connecting fails.
@Suite("SerialTransport off macOS")
struct SerialTransportStubTests {
    @Test func discoversNoPorts() {
        #expect(SerialTransport.discoverFlipperPorts().isEmpty)
    }

    @Test func connectThrows() {
        #expect(throws: TransportError.notConnected) { try SerialTransport(path: "/dev/null").connect() }
    }
}
#endif
