import Foundation
import Testing
@testable import FliBuddyCore

/// Tag dump fixtures from `protocol/fixtures/tags` (block/page lists) as `TagDump`s.
enum TagFixtures {
    private struct File: Decodable {
        var type: TagDump.Kind
        var uid: String
        var sak: UInt8
        var atqa: String
        var blocks: [String]?
        var pages: [String]?
        var missing: [Int]?
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
        try mfc(try file("bambu_pla_basic_synthetic"), missing: missing)
    }

    /// The real Bambu dump (PLA Pure, captured by the bridge in Phase 0) the way
    /// the Flipper sent it, with the sectors it was captured without.
    static func bambuReal() throws -> TagDump {
        let fixture = try file("bambu_pla_pure_real")
        return try mfc(fixture, missing: fixture.missing ?? [])
    }

    private static func mfc(_ fixture: File, missing: [Int]) throws -> TagDump {
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
        #expect(parsed.trayUuid == (try TagFixtures.bambuBlockHex(9)))
    }

    @Test func parsesTheRealBambuDump() throws {
        let dump = try TagFixtures.bambuReal()
        #expect(dump.missing == Array(3...15))
        let parsed = TagParser.parse(dump)

        #expect(parsed.kind == .bambu)
        #expect(parsed.uid == "7EF1AB04")
        #expect(parsed.trayUuid == "F1C8FDF0BC1643C0B37189ADB0687992")
        #expect(parsed.material == "PLA")
        #expect(parsed.detailedType == "PLA Pure")
        #expect(parsed.variantId == "A19-B00")
        #expect(parsed.materialId == "GFA19")
        #expect(parsed.rgba == "A4DBE8FF")
        #expect(parsed.labelWeight == 1000)
        #expect(parsed.diameter == 1.75)
        #expect(parsed.dryingTemp == 55)
        #expect(parsed.dryingHours == 8)
        #expect(parsed.nozzleMax == 230)
        #expect(parsed.nozzleMin == 190)
        #expect(parsed.hasPrefill)
        #expect(parsed.displayLines == ["PLA Pure", "#A4DBE8FF", "label 1000 g"])
    }

    @Test func parsedTagEqualsTheExpectedValue() throws {
        let expected = ParsedTag(
            kind: .bambu, uid: "5A3C9E21",
            trayUuid: try TagFixtures.bambuBlockHex(9),
            material: "PLA", detailedType: "PLA Basic", variantId: "A00-W1", materialId: "GFA00",
            rgba: "FFFFFFFF", labelWeight: 1000, diameter: 1.75,
            dryingTemp: 55, dryingHours: 8, bedTemp: 35, nozzleMax: 230, nozzleMin: 190
        )
        #expect(TagParser.parse(try TagFixtures.bambu()) == expected)
    }

    @Test func parsesTheScanFixtureWithAMissingSector() throws {
        let parsed = TagParser.parse(try TagFixtures.scanTag("scan_mfc"))
        #expect(parsed.material == "PLA")
        #expect(parsed.trayUuid == "FCFFA95B29EA71C5A36D7A067DF82014")
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
        #expect(parsed.trayUuid == (try TagFixtures.bambuBlockHex(9)))
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

    @Test func missingSector2HasNoTrayUuid() throws {
        let parsed = TagParser.parse(try TagFixtures.bambu(missing: [2]))
        #expect(parsed.trayUuid == nil)
        #expect(parsed.detailedType == "PLA Basic")
    }

    @Test func absentBlock9HasNoTrayUuid() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[9] = nil
        #expect(TagParser.parse(dump).trayUuid == nil)
    }

    @Test func zeroBlock9HasNoTrayUuid() throws {
        var dump = try TagFixtures.bambu()
        dump.blocks[9] = Array(repeating: 0, count: 16)
        #expect(TagParser.parse(dump).trayUuid == nil)
    }

    @Test func blocks4And5AreNeverATrayUuid() throws {
        // The SpoolBuddy daemon reads ASCII hex from blocks 4+5; Phase 0 showed
        // the AMS tray_uuid is block 9, so blocks 4+5 are the detailed type only.
        var dump = try TagFixtures.bambu()
        let text = Array("0123456789abcdef0123456789ABCDEF".utf8)
        dump.blocks[4] = Array(text[0..<16])
        dump.blocks[5] = Array(text[16..<32])
        dump.blocks[9] = Array(repeating: 0, count: 16)
        #expect(TagParser.parse(dump).trayUuid == nil)
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
        #expect(parsed.trayUuid == nil)
        #expect(parsed.material == nil)
        #expect(!parsed.hasPrefill)
    }

    @Test func ntagFixtureFile() throws {
        let parsed = TagParser.parse(try TagFixtures.ntag())
        #expect(parsed == ParsedTag(kind: .ntag, uid: "04112233445566"))
        #expect(!parsed.hasPrefill)
    }
}

@Suite struct ParsedTagBambuddyTagUidTests {
    @Test func bambuTagsTakeTheAmsForm() throws {
        #expect(TagParser.parse(try TagFixtures.bambuReal()).bambuddyTagUid == "7EF1AB0400000100")
        #expect(TagParser.parse(try TagFixtures.bambu()).bambuddyTagUid == "5A3C9E2100000100")
    }

    @Test func theAmsFormIsUpperCase() {
        #expect(ParsedTag(kind: .bambu, uid: "7ef1ab04").bambuddyTagUid == "7EF1AB0400000100")
    }

    @Test func ntagUidsAreSentAsRead() throws {
        #expect(TagParser.parse(try TagFixtures.ntag()).bambuddyTagUid == "04112233445566")
        #expect(ParsedTag(kind: .ntag, uid: "04a1b2c3d4e5f6").bambuddyTagUid == "04A1B2C3D4E5F6")
    }
}

@Suite struct ParsedTagBambuddySubtypeTests {
    @Test func dropsALeadingMaterialWord() {
        #expect(ParsedTag.subtype(detailedType: "PLA Pure", material: "PLA") == "Pure")
        #expect(ParsedTag.subtype(detailedType: "PLA Basic", material: "PLA") == "Basic")
        #expect(ParsedTag.subtype(detailedType: "PLA Silk+", material: "PLA") == "Silk+")
    }

    @Test func comparesTheMaterialCaseInsensitively() {
        #expect(ParsedTag.subtype(detailedType: "pla Matte", material: "PLA") == "Matte")
        #expect(ParsedTag.subtype(detailedType: "PLA Matte", material: "pla") == "Matte")
    }

    @Test func keepsATypeWhoseFirstWordIsNotTheMaterial() {
        #expect(ParsedTag.subtype(detailedType: "PETG-HF", material: "PETG") == "PETG-HF")
        #expect(ParsedTag.subtype(detailedType: "Support for PLA", material: "PLA") == "Support for PLA")
        #expect(ParsedTag.subtype(detailedType: "PLAX Basic", material: "PLA") == "PLAX Basic")
    }

    @Test func emptyOrMaterialOnlyIsNil() {
        #expect(ParsedTag.subtype(detailedType: nil, material: "PLA") == nil)
        #expect(ParsedTag.subtype(detailedType: "", material: "PLA") == nil)
        #expect(ParsedTag.subtype(detailedType: "PLA", material: "PLA") == nil)
        #expect(ParsedTag.subtype(detailedType: "PLA ", material: "PLA") == nil)
    }

    @Test func withoutAMaterialTheTypeIsKept() {
        #expect(ParsedTag.subtype(detailedType: "PLA Basic", material: nil) == "PLA Basic")
    }

    @Test func parsedTagsDeriveTheirSubtype() throws {
        #expect(TagParser.parse(try TagFixtures.bambuReal()).bambuddySubtype == "Pure")
        #expect(TagParser.parse(try TagFixtures.bambu()).bambuddySubtype == "Basic")
        #expect(TagParser.parse(try TagFixtures.ntag()).bambuddySubtype == nil)
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
