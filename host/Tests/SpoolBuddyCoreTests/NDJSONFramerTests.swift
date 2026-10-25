import Foundation
import Testing
@testable import SpoolBuddyCore

@Suite struct NDJSONFramerTests {
    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func joinsPartialPackets() {
        var framer = NDJSONFramer()
        #expect(framer.push(Data(#"{"t":"hel"#.utf8)).isEmpty)
        #expect(framer.push(Data(#"lo","v":1}"#.utf8)).isEmpty)
        #expect(strings(framer.push(Data("\n".utf8))) == [#"{"t":"hello","v":1}"#])
    }

    @Test func splitsSeveralLinesInOnePacket() {
        var framer = NDJSONFramer()
        #expect(strings(framer.push(Data("a\nb\nc".utf8))) == ["a", "b"])
        #expect(strings(framer.push(Data("\n".utf8))) == ["c"])
    }

    @Test func stripsCarriageReturnAndSkipsEmptyLines() {
        var framer = NDJSONFramer()
        #expect(strings(framer.push(Data("a\r\n\n\r\nb\n".utf8))) == ["a", "b"])
    }

    @Test func dropsOverLongLineWholeAndKeepsGoing() {
        var framer = NDJSONFramer(maxLineBytes: 8)
        // 8 bytes including "\n" fit, 9 do not.
        #expect(strings(framer.push(Data("1234567\n12345678\nok\n".utf8))) == ["1234567", "ok"])
        #expect(framer.droppedLines == 1)
    }

    @Test func dropsOverLongLineSpanningPackets() {
        var framer = NDJSONFramer(maxLineBytes: 8)
        #expect(framer.push(Data("12345".utf8)).isEmpty)
        #expect(framer.push(Data("67890".utf8)).isEmpty)
        #expect(framer.push(Data("abc".utf8)).isEmpty)
        #expect(strings(framer.push(Data("\nnext\n".utf8))) == ["next"])
        #expect(framer.droppedLines == 1)
    }

    @Test func defaultLimitIsTheProtocolLimit() {
        var framer = NDJSONFramer()
        let fits = Data(repeating: 0x61, count: Message.maxLineBytes - 1) + Data("\n".utf8)
        let tooLong = Data(repeating: 0x62, count: Message.maxLineBytes) + Data("\n".utf8)
        let lines = framer.push(fits + tooLong)
        #expect(lines.count == 1)
        #expect(lines.first?.count == Message.maxLineBytes - 1)
        #expect(framer.droppedLines == 1)
    }

    @Test func resetDiscardsPartialLine() {
        var framer = NDJSONFramer()
        _ = framer.push(Data("half".utf8))
        framer.reset()
        #expect(strings(framer.push(Data("whole\n".utf8))) == ["whole"])
    }

    @Test func framedFixturesDecode() throws {
        var framer = NDJSONFramer()
        var stream = Data()
        for name in Fixtures.validNames {
            stream += try Message.decode(line: Fixtures.message(name)).encodedLine()
        }
        // Feed the stream in odd-sized chunks.
        var decoded: [Message] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = stream.index(index, offsetBy: 97, limitedBy: stream.endIndex) ?? stream.endIndex
            decoded += try framer.push(stream[index..<end]).map { try Message.decode(line: $0) }
            index = end
        }
        #expect(decoded.count == Fixtures.validNames.count)
    }
}
