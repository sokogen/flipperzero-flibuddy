import Foundation
import Testing
@testable import SpoolBuddyCore

/// Tag dump fixtures from `protocol/fixtures/tags` (block/page lists) as `TagDump`s.
enum TagFixtures {
    private struct File: Decodable {
        var type: TagDump.Kind
        var uid: String
        var sak: UInt8
        var atqa: String
        var blocks: [String]?
        var pages: [String]?
    }

    private static func file(_ name: String) throws -> File {
        let url = Fixtures.root.appendingPathComponent("tags/\(name).json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    static func bytes(_ hex: String) throws -> [UInt8] {
        try Hex.decode(hex, byteCount: hex.utf8.count / 2, field: "fixture")
    }

    /// Raw 16-byte block `number` of the synthetic Bambu fixture, as upper-case hex.
    static func bambuBlockHex(_ number: Int) throws -> String {
        try file("bambu_pla_basic_synthetic").blocks![number]
    }

    /// The synthetic Bambu fixture the way the Flipper sends it: trailers dropped,
    /// blocks of `missing` sectors absent.
    static func bambu(missing: [Int] = []) throws -> TagDump {
        let fixture = try file("bambu_pla_basic_synthetic")
        var blocks: [Int: [UInt8]] = [:]
        for (number, hex) in fixture.blocks!.enumerated() where number % 4 != 3 && !missing.contains(number / 4) {
            blocks[number] = try bytes(hex)
        }
        return TagDump(
            type: fixture.type, uid: fixture.uid, sak: fixture.sak, atqa: fixture.atqa,
            blocks: blocks, missing: missing
        )
    }

    static func ntag() throws -> TagDump {
        let fixture = try file("ntag215_blank")
        var pages: [Int: [UInt8]] = [:]
        for (number, hex) in fixture.pages!.enumerated() {
            pages[number] = try bytes(hex)
        }
        return TagDump(type: fixture.type, uid: fixture.uid, sak: fixture.sak, atqa: fixture.atqa, pages: pages)
    }

    static func scanTag(_ name: String) throws -> TagDump {
        guard case .scan(let scan) = try Message.decode(line: Fixtures.message(name)) else {
            fatalError("\(name) is not a scan")
        }
        return scan.tag
    }
}

@Suite struct TagParserTests {
    @Test func parsesTheSyntheticBambuFixture() throws {
        let parsed = TagParser.parse(try TagFixtures.bambu())

        #expect(parsed.kind == .bambu)
        #expect(parsed.uid == "5A3C9E21")
        #expect(parsed.material == "PLA")
        #expect(parsed.detailedType == "PLA Basic")
        #expect(parsed.variantId == "A00-W1")
        #expect(parsed.materialId == "GFA00")
        #expect(parsed.rgba == "FFFFFFFF")
        #expect(parsed.labelWeight == 1000)
        #expect(parsed.diameter == 1.75)
        #expect(parsed.dryingTemp == 55)
        #expect(parsed.dryingHours == 8)
        #expect(parsed.bedTemp == 35)
        #expect(parsed.nozzleMax == 230)
        #expect(parsed.nozzleMin == 190)
        #expect(parsed.hasPrefill)
        // Block 9 raw hex first, then blocks 4+5 the daemon's way ("PLA Basic" has
        // too few hex characters, so block 4 as raw hex).
        #expect(parsed.trayUuidCandidates == [try TagFixtures.bambuBlockHex(9), try TagFixtures.bambuBlockHex(4)])
    }

    @Test func parsedTagEqualsTheExpectedValue() throws {
        let expected = ParsedTag(
            kind: .bambu, uid: "5A3C9E21",
            trayUuidCandidates: [try TagFixtures.bambuBlockHex(9), try TagFixtures.bambuBlockHex(4)],
            material: "PLA", detailedType: "PLA Basic", variantId: "A00-W1", materialId: "GFA00",
            rgba: "FFFFFFFF", labelWeight: 1000, diameter: 1.75,
            dryingTemp: 55, dryingHours: 8, bedTemp: 35, nozzleMax: 230, nozzleMin: 190
        )
        #expect(TagParser.parse(try TagFixtures.bambu()) == expected)
    }

    @Test func parsesTheScanFixtureWithAMissingSector() throws {
        let parsed = TagParser.parse(try TagFixtures.scanTag("scan_mfc"))
        #expect(parsed.material == "PLA")
        #expect(parsed.trayUuidCandidates.count == 2)
    }

    @Test func missingSector1DropsTheSector1Fields() throws {
        let parsed = TagParser.parse(try TagFixtures.bambu(missing: [1]))
        #expect(parsed.kind == .bambu)
        #expect(parsed.material == "PLA")  // block 2 is in sector 0
        #expect(parsed.detailedType == nil)
        #expect(parsed.rgba == nil)
        #expect(parsed.labelWeight == nil)
        #expect(parsed.diameter == nil)
        #expect(parsed.nozzleMin == nil)
        #expect(parsed.trayUuidCandidates == [try TagFixtures.bambuBlockHex(9)])
    }

    @Test func missingSector0HasNoMaterialAndNoPrefill() throws {
        let parsed = TagParser.parse(try TagFixtures.bambu(missing: [0]))
        #expect(parsed.material == nil)
        #expect(parsed.variantId == nil)
        #expect(parsed.materialId == nil)
        #expect(!parsed.hasPrefill)
    }

    @Test func blocksOfAMissingSectorAreIgnoredEvenWhenPresent() throws {
        var dump = try TagFixtures.bambu()
        dump.missing = [0]
        #expect(TagParser.parse(dump).material == nil)
    }

    @Test func missingSector2HasNoBlock9Candidate() throws {
        let parsed = TagParser.parse(try TagFixtures.bambu(missing: [2]))
        #expect(parsed.trayUuidCandidates == [try TagFixtures.bambuBlockHex(4)])
    }

    @Test func asciiHexTrayUuidInBlocks4And5() throws {
        var dump = try TagFixtures.bambu()
        let text = Array("0123456789abcdef0123456789ABCDEF".utf8)
        dump.blocks[4] = Array(text[0..<16])
        dump.blocks[5] = Array(text[16..<32])
        #expect(TagParser.parse(dump).trayUuidCandidates[1] == "0123456789ABCDEF0123456789ABCDEF")
    }

    @Test func zeroBlocksGiveNoCandidates() throws {
        var dump = try TagFixtures.bambu()
        for block in [4, 5, 9] {
            dump.blocks[block] = Array(repeating: 0, count: 16)
        }
        #expect(TagParser.parse(dump).trayUuidCandidates.isEmpty)
    }

    @Test func duplicateCandidatesAreCollapsed() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[9] = dump.blocks[4]
        #expect(TagParser.parse(dump).trayUuidCandidates == [try TagFixtures.bambuBlockHex(4)])
    }

    @Test func zeroLabelWeightReadsAsUnknown() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[5]![4] = 0
        dump.blocks[5]![5] = 0
        #expect(TagParser.parse(dump).labelWeight == nil)
    }

    @Test func zeroTemperaturesReadAsUnknown() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[6] = Array(repeating: 0, count: 16)
        let parsed = TagParser.parse(dump)
        #expect(parsed.dryingTemp == nil)
        #expect(parsed.dryingHours == nil)
        #expect(parsed.bedTemp == nil)
        #expect(parsed.nozzleMax == nil)
        #expect(parsed.nozzleMin == nil)
    }

    @Test func nonAsciiMaterialReadsAsUnknown() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[2] = Array(repeating: 0xFF, count: 16)
        let parsed = TagParser.parse(dump)
        #expect(parsed.material == nil)
        #expect(!parsed.hasPrefill)
    }

    @Test func blankOrSpacesOnlyMaterialReadsAsUnknown() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[2] = Array(repeating: 0, count: 16)
        #expect(TagParser.parse(dump).material == nil)
        dump.blocks[2] = Array("   ".utf8) + Array(repeating: 0, count: 13)
        #expect(TagParser.parse(dump).material == nil)
    }

    @Test func lowerCaseUidIsUpperCased() throws {
        var dump = try TagFixtures.bambu()
        dump.uid = "5a3c9e21"
        #expect(TagParser.parse(dump).uid == "5A3C9E21")
    }

    @Test func ntagScanFixtureIsUidOnly() throws {
        let parsed = TagParser.parse(try TagFixtures.scanTag("scan_ntag"))
        #expect(parsed.kind == .ntag)
        #expect(parsed.uid == "04112233445566")
        #expect(parsed.trayUuidCandidates.isEmpty)
        #expect(parsed.material == nil)
        #expect(!parsed.hasPrefill)
    }

    @Test func ntagFixtureFile() throws {
        let parsed = TagParser.parse(try TagFixtures.ntag())
        #expect(parsed == ParsedTag(kind: .ntag, uid: "04112233445566"))
        #expect(!parsed.hasPrefill)
    }
}

@Suite struct ParsedTagDisplayLinesTests {
    @Test func bambuLinesMatchTheLookupFixture() throws {
        guard case .lookup(let lookup) = try Message.decode(line: Fixtures.message("lookup_unknown")) else {
            Issue.record("lookup_unknown is not a lookup")
            return
        }
        #expect(TagParser.parse(try TagFixtures.bambu()).displayLines == lookup.lines)
    }

    @Test func ntagLines() throws {
        #expect(TagParser.parse(try TagFixtures.ntag()).displayLines == ["NTAG", "UID 04112233445566"])
    }

    @Test func bambuWithoutDataShowsTheUid() throws {
        let lines = TagParser.parse(try TagFixtures.bambu(missing: [0, 1])).displayLines
        #expect(lines == ["Bambu tag", "UID 5A3C9E21"])
    }

    @Test func materialIsUsedWithoutADetailedType() throws {
        let tag = ParsedTag(kind: .bambu, uid: "5A3C9E21", material: "PETG")
        #expect(tag.displayLines == ["PETG", "UID 5A3C9E21"])
    }

    @Test func linesFitTheFlipperScreen() throws {
        let long = String(repeating: "Z", count: 60)
        let tags = [
            ParsedTag(kind: .bambu, uid: "5A3C9E21", detailedType: long, rgba: "FFFFFFFF", labelWeight: 1000),
            ParsedTag(kind: .ntag, uid: String(repeating: "A", count: 40)),
            TagParser.parse(try TagFixtures.bambu(missing: [0, 1])),
            TagParser.parse(try TagFixtures.bambu()),
        ]
        for tag in tags {
            let lines = tag.displayLines
            #expect((1...ParsedTag.maxLines).contains(lines.count))
            #expect(lines.allSatisfy { $0.count <= ParsedTag.maxLineLength })
        }
        #expect(tags[0].displayLines[0] == String(repeating: "Z", count: 40))
    }
}
