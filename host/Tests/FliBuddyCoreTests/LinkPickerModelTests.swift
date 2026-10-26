import Foundation
import Testing
@testable import FliBuddyCore

/// The row the picker links: the synthetic NTAG or Bambu fixture, without a spool.
private func item(_ name: String = "scan_ntag", spool: Spool? = nil) throws -> FeedItem {
    FeedItem(FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: .unknown(prefill: false)))
}

private func spools() -> [Spool] {
    [
        Spool(id: 1, material: "PLA", subtype: "PLA Matte", colorName: "Charcoal", brand: "Bambu Lab",
              labelWeight: 1000, coreWeight: 250, weightUsed: 0),
        Spool(id: 2, material: "PETG", colorName: "Translucent Teal", brand: "Polymaker",
              labelWeight: 1000, coreWeight: 200, weightUsed: 400, tagUid: "04AABBCCDDEEFF", note: "shelf B"),
        Spool(id: 3, material: "TPU", brand: "eSUN", labelWeight: 500, coreWeight: 150, weightUsed: 0,
              note: "for gaskets"),
    ]
}

@Suite("LinkPickerModel")
struct LinkPickerModelTests {
    @Test func theFilterMatchesMaterialColourBrandAndNoteCaseInsensitively() {
        let all = spools()
        #expect(LinkPickerModel.filter(all, query: "").map(\.id) == [1, 2, 3])
        #expect(LinkPickerModel.filter(all, query: "  ").map(\.id) == [1, 2, 3])
        #expect(LinkPickerModel.filter(all, query: "petg").map(\.id) == [2])
        #expect(LinkPickerModel.filter(all, query: "CHARCOAL").map(\.id) == [1])
        #expect(LinkPickerModel.filter(all, query: "polymaker").map(\.id) == [2])
        #expect(LinkPickerModel.filter(all, query: "Gaskets").map(\.id) == [3])
        #expect(LinkPickerModel.filter(all, query: "matte").map(\.id) == [1])
        #expect(LinkPickerModel.filter(all, query: "teal shelf").map(\.id) == [2])
        #expect(LinkPickerModel.filter(all, query: "teal gaskets").isEmpty)
        #expect(LinkPickerModel.filter(all, query: "nylon").isEmpty)
    }

    @Test func theHeaderNamesTheTag() throws {
        let picker = LinkPickerModel(item: try item(), spools: spools())
        #expect(LinkPickerModel.title == "Link to existing spool")
        #expect(picker.tagLine == "Tag 04112233445566")
        #expect(LinkPickerModel.placeholder == "material, colour, brand or note")
    }

    @Test func matchesFollowTheQueryAndLeaveOutTheRowsOwnSpool() throws {
        let own = Spool(id: 100, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 0,
                        tagUid: "5A3C9E2100000100")
        let created = try item("scan_mfc", spool: own)
        let picker = LinkPickerModel(item: created, spools: spools() + [own], query: "pla")
        #expect(picker.matches.map(\.id) == [1])
    }

    @Test func rowsShowColourBrandAndWhatIsLeft() {
        let all = spools()
        #expect(LinkPickerModel.subtitle(all[0]) == "Charcoal · Bambu Lab · 1000 g left")
        #expect(LinkPickerModel.subtitle(all[1]) == "Translucent Teal · Polymaker · 600 g left")
        #expect(LinkPickerModel.subtitle(all[2]) == "eSUN · 500 g left")
    }

    @Test func aTaggedSpoolCarriesABadge() {
        let all = spools()
        #expect(LinkPickerModel.badge(all[0]) == nil)
        #expect(LinkPickerModel.badge(all[1]) == "Tag 04AABBCCDDEEFF")
        let trayOnly = Spool(id: 4, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 0,
                             trayUuid: "ABCD")
        #expect(LinkPickerModel.badge(trayOnly) == "Tag ABCD")
    }

    @Test func noMatchSaysSo() throws {
        let row = try item()
        #expect(LinkPickerModel(item: row, spools: spools(), query: "nylon").emptyText == "No spools match \u{201C}nylon\u{201D}.")
        #expect(LinkPickerModel(item: row, spools: spools(), query: "pla").emptyText == nil)
        #expect(LinkPickerModel(item: row, spools: []).emptyText == "No spools in Bambuddy.")
    }

    @Test func aPickWithoutATagLinks() throws {
        let picker = LinkPickerModel(item: try item(), spools: spools(), selection: 1)
        #expect(picker.warning == nil)
        #expect(picker.linkTitle == "Link")
        #expect(picker.canLink)
    }

    @Test func aPickCarryingAnotherTagWarnsAndMovesTheLink() throws {
        let picker = LinkPickerModel(item: try item(), spools: spools(), selection: 2)
        #expect(picker.warning == "PETG Translucent Teal is linked to tag 04AABBCCDDEEFF. Linking moves it to 04112233445566.")
        #expect(picker.linkTitle == "Move link")
        #expect(picker.canLink)
    }

    /// Bambuddy keeps a Bambu tag's UID in the AMS form, with `00000100` after it.
    @Test func aPickCarryingThisTagDoesNotWarn() throws {
        let same = Spool(id: 5, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 0,
                         tagUid: "5A3C9E2100000100")
        let picker = LinkPickerModel(item: try item("scan_mfc"), spools: [same], selection: 5)
        #expect(picker.warning == nil)
        #expect(picker.linkTitle == "Link")
    }

    @Test func linkNeedsAPickAmongTheMatches() throws {
        let row = try item()
        #expect(!LinkPickerModel(item: row, spools: spools()).canLink)
        // the pick was filtered out
        #expect(!LinkPickerModel(item: row, spools: spools(), query: "tpu", selection: 1).canLink)
        #expect(LinkPickerModel(item: row, spools: spools(), query: "tpu", selection: 1).warning == nil)
    }
}
