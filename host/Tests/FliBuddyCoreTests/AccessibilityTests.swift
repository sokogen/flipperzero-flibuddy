import Foundation
import Testing
@testable import FliBuddyCore

@Suite("Colour words for VoiceOver")
struct ColorWordTests {
    private func word(_ rgba: String) -> String? {
        Swatch(rgba: rgba)?.colorWord
    }

    @Test func greysAreNamedByLightness() {
        #expect(word("FFFFFFFF") == "white")
        #expect(word("000000FF") == "black")
        #expect(word("8E9089FF") == "gray")
        #expect(word("D1D3D5FF") == "light gray")
        #expect(word("545454FF") == "dark gray")
    }

    @Test func coloursAreNamedByHueAndLightness() {
        #expect(word("00AE42FF") == "green")
        #expect(word("0A2989FF") == "dark blue")
        #expect(word("FF6A13FF") == "orange")
        #expect(word("C12E1FFF") == "red")
        #expect(word("F4EE2AFF") == "yellow")
        #expect(word("9D432CFF") == "brown")
        #expect(word("8E44ADFF") == "purple")
        #expect(word("F5A3C7FF") == "pink")
        #expect(word("00B1B7FF") == "teal")
        #expect(word("9CDBD9FF") == "light teal")
    }

    @Test func seeThroughColoursSaySo() {
        #expect(word("FFFFFF00") == "clear")
        #expect(word("0A298980") == "translucent dark blue")
    }

    @Test func aFeedRowReadsBambuddysNameFirst() throws {
        let item = FeedItem(FeedRow(scanId: "s-1", dump: try fixtureScan().tag, spool: knownSpool(), status: .awaitingWeight))
        #expect(item.spokenColor == "Jade White")
    }

    @Test func withoutBambuddysNameAFeedRowReadsTheTagsBambuName() throws {
        let row = FeedRow(scanId: "s-1", dump: try fixtureScan().tag, spool: knownSpool(colorName: nil), status: .awaitingWeight)
        let bambu = try #require(row.tag.bambuColor)
        let item = FeedItem(row)
        #expect(item.colorName == nil)
        #expect(item.spokenColor == bambu.name)
        #expect(item.accessibilityHeader.contains(", \(bambu.name), "))
    }

    @Test func withoutAnyNameAFeedRowReadsTheColourWord() throws {
        let tag = try fixtureScan("scan_ntag").tag
        var spool = knownSpool(colorName: nil)
        spool.rgba = "0A2989FF"
        let item = FeedItem(FeedRow(scanId: "s-1", dump: tag, spool: spool, status: .awaitingWeight))
        #expect(item.spokenColor == "dark blue")
        #expect(item.accessibilityHeader.hasPrefix("PLA Basic, dark blue, "))
        // The colour line on screen still leaves an unnamed colour out.
        #expect(!item.detailText.contains("blue"))
    }

    @Test func aSpoolWithoutANameReadsTheColourWord() {
        var spool = knownSpool(colorName: nil)
        spool.rgba = "00AE42FF"
        let row = SpoolsViewModel.row(spool, now: Date(), locale: Locale(identifier: "en_US"))
        #expect(row.accessibilityLabel.hasPrefix("PLA Basic, green, Bambu Lab, "))
        #expect(row.subtitle == "Bambu Lab")
    }
}

@MainActor
@Suite("Status chips read with their side")
struct ChipLabelTests {
    @Test func eachActionNamesItsSide() {
        #expect(StatusItem.Action.retry.accessibilityLabel(for: "Bambuddy") == "Retry Bambuddy")
        #expect(StatusItem.Action.check.accessibilityLabel(for: "Bambuddy") == "Check Bambuddy")
        #expect(StatusItem.Action.connect.accessibilityLabel(for: "Flipper") == "Connect Flipper")
        #expect(StatusItem.Action.settings.accessibilityLabel(for: "Flipper") == "Flipper settings")
    }

    @Test func theSidebarRowsNameTheirSide() {
        let sidebar = Sidebar(
            flipper: FlipperLink.statusItem(.disconnected, choice: nil, port: nil, problem: nil, isActive: false),
            bambuddy: BambuddyState.unchecked.statusItem(), flipperName: nil, serverURL: "", feedCount: 0
        )
        #expect(sidebar.flipper.actionAccessibilityLabel == "Flipper settings")
        #expect(sidebar.bambuddy.actionAccessibilityLabel == "Check Bambuddy")
    }
}
