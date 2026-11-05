import Foundation
import Testing
@testable import FliBuddyCore

private func row(
    _ name: String = "scan_mfc", status: FeedRow.Status = .awaitingWeight, spool: Spool? = nil
) throws -> FeedRow {
    var row = FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: status)
    row.status = status
    return row
}

@Suite("TagDetails")
struct TagDetailsTests {
    @Test func aBambuTagOnAKnownSpoolListsEveryFact() throws {
        var spool = knownSpool()
        spool.materialNumber = "10501"
        let details = TagDetails(try row(spool: spool))

        #expect(details.title == "PLA Basic")
        #expect(details.facts.map(\.label) == [
            "UID", "Bambuddy tag UID", "Tray UUID", "Color", "Color code", "Filament ID", "RGBA",
            "Diameter", "Nozzle", "Label weight", "Core weight", "Spool",
        ])
        #expect(details.value("UID") == "5A3C9E21")
        #expect(details.value("Bambuddy tag UID") == "5A3C9E2100000100")
        #expect(details.value("Tray UUID") == "FCFFA95B29EA71C5A36D7A067DF82014")
        #expect(details.value("Color") == "Jade White")
        #expect(details.value("Color code") == "10501")
        #expect(details.value("Filament ID") == "GFA00")
        #expect(details.value("RGBA") == "#FFFFFFFF")
        #expect(details.value("Diameter") == "1.75 mm")
        #expect(details.value("Nozzle") == "190\u{2013}230 °C")
        #expect(details.value("Label weight") == "\(Grams.text(1000)) g")
        #expect(details.value("Core weight") == "250 g")
        #expect(details.value("Spool") == "#42")
        // identifiers are monospaced and selectable; the rest is plain text
        let identifiers = details.facts.filter(\.isIdentifier).map(\.label)
        #expect(identifiers == ["UID", "Bambuddy tag UID", "Tray UUID", "Filament ID", "RGBA"])
    }

    @Test func aTagWithoutASpoolShowsTheTagsOwnFacts() throws {
        var unknown = try row(status: .unknown(prefill: true))
        unknown.colorName = "Jade White"
        let details = TagDetails(unknown)

        #expect(details.value("Color code") == "10100")
        #expect(details.value("Label weight") == "\(Grams.text(1000)) g")
        #expect(details.value("Core weight") == nil)
        #expect(details.value("Spool") == nil)
    }

    @Test func anArchivedSpoolSaysSo() throws {
        var spool = knownSpool()
        spool.archived = true
        #expect(TagDetails(try row(spool: spool)).value("Spool") == "#42 · archived")
    }

    @Test func aBlankNTAGShowsOnlyWhatItKnows() throws {
        let details = TagDetails(try row("scan_ntag", status: .unknown(prefill: false)))
        #expect(details.title == "NTAG 7-byte UID 0411\u{2026}")
        // the Bambuddy UID of an NTAG is its UID, so it is not repeated
        #expect(details.facts.map(\.label) == ["UID"])
    }

    @Test func nozzleAndDiameterFormats() {
        #expect(TagDetails.nozzle(min: 190, max: 230) == "190\u{2013}230 °C")
        #expect(TagDetails.nozzle(min: 220, max: nil) == "220 °C")
        #expect(TagDetails.nozzle(min: nil, max: 240) == "240 °C")
        #expect(TagDetails.nozzle(min: 230, max: 230) == "230 °C")
        #expect(TagDetails.nozzle(min: nil, max: nil) == nil)
        #expect(TagDetails.diameter(1.75) == "1.75 mm")
        #expect(TagDetails.diameter(2.85) == "2.85 mm")
        #expect(TagDetails.diameter(0) == nil)
    }

    @MainActor
    @Test func theFeedGivesTheDetailsOfARow() async throws {
        let session = Session(settings: testSettings, inventory: FakeInventory(spools: [knownSpool()]))
        let model = FeedViewModel(session: session, settings: testSettings)
        let id = await session.record(try fixtureScan())
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(model.tagDetails(for: id)?.value("Spool") == "#42")
        #expect(model.tagDetails(for: UUID()) == nil)
    }
}
