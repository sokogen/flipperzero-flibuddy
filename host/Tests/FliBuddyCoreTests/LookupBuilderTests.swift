import Foundation
import Testing
@testable import FliBuddyCore

@Suite("LookupBuilder")
struct LookupBuilderTests {
    @Test func aFoundLookupCarriesTheSpool() {
        let lookup = LookupBuilder.found(scanId: "s-1", spool: knownSpool())
        #expect(lookup.spool == SpoolSummary(
            id: 42, material: "PLA", subtype: "Basic", colorName: "Jade White", rgba: "FFFFFFFF",
            remaining: 484, label: 1000, core: 250
        ))
        #expect(lookup.created == false)
    }

    @Test func aCreatedLookupSaysSo() throws {
        let line = try Message.lookup(LookupBuilder.found(scanId: "s-1", spool: knownSpool(), created: true)).encodedLine()
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        #expect(object["created"] as? Bool == true)
    }

    /// Bambuddy keeps legacy values as they are; the reply must still encode,
    /// or the link would drop.
    @Test func oddBambuddyDataIsCleanedUpBeforeItGoesOut() throws {
        var spool = knownSpool(colorName: String(repeating: "Jade White ", count: 6), subtype: "")
        spool.rgba = "#fff"
        spool.labelWeight = 12000
        spool.coreWeight = -5
        let lookup = LookupBuilder.found(scanId: "s-1", spool: spool)

        let summary = try #require(lookup.spool)
        #expect(summary.subtype == nil)
        #expect(summary.colorName?.count == 40)
        #expect(summary.rgba == nil)
        #expect(summary.label == 9999)
        #expect(summary.core == 0)
        _ = try Message.lookup(lookup).encodedLine()
    }

    @Test func aLowerCaseColourIsUpperCased() {
        var spool = knownSpool()
        spool.rgba = "00ae42ff"
        #expect(LookupBuilder.summary(spool)?.rgba == "00AE42FF")
    }

    @Test func aSpoolWithoutMaterialGoesOutWithoutTheSpoolObject() throws {
        var spool = knownSpool()
        spool.material = ""
        let lookup = LookupBuilder.found(scanId: "s-1", spool: spool)
        #expect(lookup.spool == nil)
        #expect(lookup.spoolId == 42)
        _ = try Message.lookup(lookup).encodedLine()
    }

    @Test func anArchivedSpoolSaysArchivedInPlaceOfTheRemainingLine() {
        var spool = knownSpool(lastScaleWeight: 250, weightUsed: 1000)
        spool.archived = true
        let lookup = LookupBuilder.found(scanId: "s-1", spool: spool)
        #expect(lookup.lines == ["PLA Basic", "Jade White", "archived", "core 250 g"])
        #expect(lookup.spool?.archived == true)
    }

    @Test func anUnknownBambuTagCarriesWhatTheTagSays() throws {
        let tag = TagParser.parse(try fixtureScan().tag)
        let lookup = LookupBuilder.unknown(scanId: "s-1", tag: tag, core: 250, colorName: "Jade White")
        #expect(
            lookup.tagInfo == TagInfo(
            material: "PLA", subtype: "Basic", rgba: "FFFFFFFF", label: 1000, colorName: "Jade White",
            code: "10100", filamentId: "GFA00", diameter: "1.75", nozzleMin: 190, nozzleMax: 230
        )
        )
        // without a colour name the rest is still there
        let unnamed = LookupBuilder.unknown(scanId: "s-1", tag: tag, core: 250)
        #expect(unnamed.tagInfo?.colorName == nil)
        #expect(unnamed.tagInfo?.code == "10100")
        #expect(unnamed.tagInfo?.filamentId == "GFA00")
    }

    @Test func aBlankTagHasNoTagInfo() throws {
        let tag = TagParser.parse(try fixtureScan("scan_ntag").tag)
        #expect(LookupBuilder.unknown(scanId: "s-1", tag: tag, core: 250).tagInfo == nil)
    }

    @Test func aResultCarriesTheSpoolOnlyWhenItSucceeded() {
        let ok = LookupBuilder.result(id: "i-1", ok: true, lines: ["Saved"], spool: knownSpool())
        #expect(ok.spool?.id == 42)
        let failed = LookupBuilder.result(id: "i-1", ok: false, lines: ["Not saved"], error: "boom", spool: knownSpool())
        #expect(failed.spool == nil)
    }

    @Test func namesForTheFlipperAreASCII() {
        // The Flipper's fonts draw ASCII only.
        #expect(LookupBuilder.name("Gr\u{00FC}n Caf\u{00E9}") == "Grun Cafe")
        #expect(LookupBuilder.name("Stra\u{00DF}e \u{00B7} \u{201C}Silk\u{201D}") == "Strasse - \"Silk\"")
        #expect(LookupBuilder.name("\u{0417}\u{0435}\u{043B}\u{0451}\u{043D}\u{044B}\u{0439}") == "Zelenyj")
        #expect(LookupBuilder.name("\u{1F525}") == nil)
        // Transliterated first, then cut to 40.
        let long = LookupBuilder.name(String(repeating: "\u{00DF}", count: 30))
        #expect(long == String(repeating: "ss", count: 20))
        #expect(LookupBuilder.lines("Bambuddy: Gr\u{00FC}n") == ["Bambuddy: Grun"])
        #expect(LookupBuilder.message("\u{00C9}chec") == "Echec")
    }
}
