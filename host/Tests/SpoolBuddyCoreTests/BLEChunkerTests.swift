import Foundation
import Testing
@testable import SpoolBuddyCore

@Suite struct BLEChunkerTests {
    private let hello = Message.hello(Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1"))

    /// Hands out and confirms every write, returning them in order.
    private func drain(_ chunker: inout BLEChunker) -> [Data] {
        var writes: [Data] = []
        while let write = chunker.nextWrite() {
            writes.append(write)
            chunker.writeConfirmed()
        }
        return writes
    }

    @Test func defaultsToTheMinimumAttPayload() {
        #expect(BLEChunker().writeSize == 20)
    }

    @Test func writeSizeIsCappedAt243AndAtLeastOne() {
        var chunker = BLEChunker(writeSize: 512)
        #expect(chunker.writeSize == 243)
        chunker.writeSize = 244
        #expect(chunker.writeSize == BLEChunker.maxWriteSize)
        chunker.writeSize = 0
        #expect(chunker.writeSize == 1)
        #expect(BLEChunker(writeSize: -5).writeSize == 1)
    }

    @Test func lineAtTheCapGoesOutInOneWrite() throws {
        var chunker = BLEChunker(writeSize: 243)
        try chunker.enqueue(line: Data(repeating: 0x61, count: 242))
        let writes = drain(&chunker)
        #expect(writes.count == 1)
        #expect(writes.first?.count == 243)
        #expect(writes.first?.last == 0x0A)
    }

    @Test func lineOneByteOverTheSizeTakesTwoWrites() throws {
        var chunker = BLEChunker(writeSize: 20)
        try chunker.enqueue(line: Data(repeating: 0x61, count: 20))
        #expect(drain(&chunker).map(\.count) == [20, 1])
    }

    @Test func longLineCrossesSeveralWritesInOrder() throws {
        var chunker = BLEChunker(writeSize: 182)
        let line = Data((0..<2000).map { UInt8(0x21 + $0 % 90) })
        try chunker.enqueue(line: line)
        let writes = drain(&chunker)
        #expect(writes.count == 11)
        #expect(writes.dropLast().allSatisfy { $0.count == 182 })
        #expect(writes.reduce(Data(), +) == line + Data([0x0A]))
    }

    @Test func nothingIsHandedOutWhileAWriteIsInFlight() throws {
        var chunker = BLEChunker(writeSize: 4)
        try chunker.enqueue(line: Data("abcdefg".utf8))
        #expect(chunker.nextWrite() == Data("abcd".utf8))
        #expect(chunker.isWriteInFlight)
        #expect(chunker.nextWrite() == nil)
        #expect(chunker.nextWrite() == nil)
        chunker.writeConfirmed()
        #expect(!chunker.isWriteInFlight)
        #expect(chunker.nextWrite() == Data("efg\n".utf8))
        chunker.writeConfirmed()
        #expect(chunker.nextWrite() == nil)
        #expect(!chunker.hasPendingWrites)
    }

    @Test func confirmingWithNothingInFlightIsHarmless() throws {
        var chunker = BLEChunker(writeSize: 4)
        chunker.writeConfirmed()
        try chunker.enqueue(line: Data("ab".utf8))
        #expect(chunker.nextWrite() == Data("ab\n".utf8))
    }

    @Test func linesQueuedBehindAWriteFollowInOrder() throws {
        var chunker = BLEChunker(writeSize: 5)
        try chunker.enqueue(line: Data("one".utf8))
        let first = chunker.nextWrite()
        try chunker.enqueue(line: Data("two".utf8))
        chunker.writeConfirmed()
        let rest = drain(&chunker)
        #expect(([first].compactMap { $0 } + rest).reduce(Data(), +) == Data("one\ntwo\n".utf8))
    }

    @Test func enqueuesAnEncodedMessage() throws {
        var chunker = BLEChunker(writeSize: 243)
        try chunker.enqueue(hello)
        #expect(drain(&chunker).reduce(Data(), +) == (try hello.encodedLine()))
    }

    @Test func emptyLineSendsNothing() throws {
        var chunker = BLEChunker()
        try chunker.enqueue(line: Data())
        #expect(!chunker.hasPendingWrites)
        #expect(chunker.nextWrite() == nil)
    }

    @Test func lineAtTheProtocolLimitIsAccepted() throws {
        var chunker = BLEChunker(writeSize: 243)
        try chunker.enqueue(line: Data(repeating: 0x61, count: Message.maxLineBytes - 1))
        #expect(drain(&chunker).reduce(0) { $0 + $1.count } == Message.maxLineBytes)
    }

    @Test func oversizeLineIsRejectedAndQueuesNothing() {
        var chunker = BLEChunker()
        #expect(throws: ProtocolError.lineTooLong(Message.maxLineBytes + 1)) {
            try chunker.enqueue(line: Data(repeating: 0x61, count: Message.maxLineBytes))
        }
        #expect(!chunker.hasPendingWrites)
    }

    @Test func writeSizeChangeAppliesToTheNextWrite() throws {
        var chunker = BLEChunker(writeSize: 20)
        let line = Data((0..<99).map { UInt8(0x41 + $0 % 26) })
        try chunker.enqueue(line: line)
        let next = chunker.nextWrite()
        let first = try #require(next)
        chunker.writeSize = 50
        chunker.writeConfirmed()
        let rest = drain(&chunker)
        #expect(([first] + rest).map(\.count) == [20, 50, 30])
        #expect(([first] + rest).reduce(Data(), +) == line + Data([0x0A]))
    }

    @Test func notificationsSplitMidLineReassemble() throws {
        var chunker = BLEChunker()
        let line = try hello.encodedLine()
        var messages: [Message] = []
        for start in stride(from: 0, to: line.count, by: 7) {
            messages += chunker.receive(line[start..<min(start + 7, line.count)])
        }
        #expect(messages == [hello])
    }

    @Test func oneNotificationCanCompleteSeveralMessages() throws {
        var chunker = BLEChunker()
        let line = try hello.encodedLine()
        #expect(chunker.receive(line.prefix(10)).isEmpty)
        #expect(chunker.receive(line.dropFirst(10) + line) == [hello, hello])
    }

    @Test func undecodableAndOversizeInboundLinesAreDropped() throws {
        var chunker = BLEChunker()
        let garbage = Data("not json\n".utf8)
        let tooLong = Data(repeating: 0x61, count: Message.maxLineBytes) + Data([0x0A])
        let line = try hello.encodedLine()
        #expect(chunker.receive(garbage + tooLong + line) == [hello])
        #expect(chunker.receive(Data()).isEmpty)
    }

    @Test func resetDropsQueuedWritesAndPartialInbound() throws {
        var chunker = BLEChunker(writeSize: 4)
        try chunker.enqueue(line: Data("abcdefg".utf8))
        _ = chunker.nextWrite()
        _ = chunker.receive(Data(#"{"t":"hel"#.utf8))
        chunker.reset()
        #expect(!chunker.isWriteInFlight)
        #expect(!chunker.hasPendingWrites)
        #expect(chunker.nextWrite() == nil)
        #expect(chunker.receive(try hello.encodedLine()) == [hello])
        #expect(chunker.writeSize == 4)
    }
}
