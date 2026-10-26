import Foundation
import Testing
@testable import FliBuddyCore

@Suite struct WireLogTests {
    @Test func aShortLineIsKeptWithoutItsTerminator() {
        #expect(WireLog.excerpt(Data(#"{"t":"hello"}"#.utf8 + [0x0A]), limit: 300) == #"{"t":"hello"}"#)
        #expect(WireLog.excerpt(Data("abc\r\n".utf8), limit: 3) == "abc")
    }

    @Test func aLongLineIsCutAtTheLimitWithTheRestCounted() {
        let line = String(repeating: "a", count: 300) + "é" + String(repeating: "b", count: 10)
        // "é" is two bytes.
        #expect(WireLog.excerpt(Data(line.utf8), limit: 300) == String(repeating: "a", count: 300) + "… (+12 bytes)")
        #expect(WireLog.excerpt(Data(line.utf8), limit: 301) == String(repeating: "a", count: 300) + "é… (+10 bytes)")
    }

    @Test func aSentLineIsLoggedAtDebug() async throws {
        let line = try Message.hostHello.encodedLine()
        let quiet = await capturingLog { WireLog.sent(line) }
        let loud = await capturingLog(level: .debug) { WireLog.sent(line) }

        #expect(quiet.events.isEmpty)
        #expect(loud.events == [#"wire tx: {"app":"flibuddy-mac/0.1.0","os":"macOS 26.0","t":"hello","v":1}"#])
        #expect(loud.lines.map(\.level) == [.debug])
    }

    @Test func aReceivedLineIsDecodedAndLoggedAtDebug() async throws {
        let line = try Message.flipperHello.encodedLine().dropLast()
        var message: Message?
        let sink = await capturingLog(level: .debug) { message = WireLog.received(Data(line)) }

        #expect(message == .flipperHello)
        #expect(sink.events == ["wire rx: \(String(decoding: line, as: UTF8.self))"])
    }

    @Test func aLineThatDoesNotDecodeIsDroppedAtErrorWithTheReasonAndItsStart() async {
        var messages: [Message?] = []
        let long = #"{"t":"ping","v":1,"pad":""# + String(repeating: "x", count: 200) + #""}"#
        let sink = await capturingLog {
            messages.append(WireLog.received(Data(#"{"t":"ping","v":1}"#.utf8)))
            messages.append(WireLog.received(Data(#"{"t":"hello","v":2,"app":"x"}"#.utf8)))
            messages.append(WireLog.received(Data(long.utf8)))
            messages.append(WireLog.received(Data("not json".utf8)))
        }

        #expect(messages == [nil, nil, nil, nil])
        #expect(sink.lines.map(\.level) == [.error, .error, .error, .error])
        let events = sink.events
        #expect(events.count == 4)
        #expect(events[0] == #"wire dropped: reason=unknown type ping line={"t":"ping","v":1}"#)
        #expect(events[1] == #"wire dropped: reason=unsupported version 2 line={"t":"hello","v":2,"app":"x"}"#)
        #expect(events[2] == "wire dropped: reason=unknown type ping line=\(long.prefix(120))… (+\(long.utf8.count - 120) bytes)")
        #expect(events[3].hasPrefix("wire dropped: reason=malformed: "))
        #expect(events[3].hasSuffix(" line=not json"))
    }

    @Test func receivingFramesDecodesAndReportsOverLongLines() async throws {
        var framer = NDJSONFramer(maxLineBytes: 64)
        var messages: [Message] = []
        let hello = try Message.flipperHello.encodedLine()
        let sink = await capturingLog {
            messages = WireLog.receive(Data(String(repeating: "x", count: 100).utf8 + [0x0A]) + hello, framer: &framer)
        }

        #expect(messages == [.flipperHello])
        #expect(sink.events == ["wire dropped: reason=line too long, over 64 bytes"])
    }

    @Test func protocolErrorsReadAsReasons() {
        #expect(WireLog.reason(ProtocolError.unknownType("ping")) == "unknown type ping")
        #expect(WireLog.reason(ProtocolError.unsupportedVersion(2)) == "unsupported version 2")
        #expect(WireLog.reason(ProtocolError.malformed("no t")) == "malformed: no t")
        #expect(WireLog.reason(ProtocolError.invalid("scan.uid")) == "invalid scan.uid")
        #expect(WireLog.reason(ProtocolError.lineTooLong(9000)) == "line too long, 9000 bytes")
        struct Other: Error {}
        #expect(WireLog.reason(Other()) == "Other()")
    }

    @Test func durationsReadInSecondsOrMilliseconds() {
        #expect(Duration.seconds(2).logDescription == "2s")
        #expect(Duration.milliseconds(50).logDescription == "50ms")
        #expect(Duration.milliseconds(1500).logDescription == "1500ms")
    }
}
