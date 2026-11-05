import Foundation
import Testing
@testable import FliBuddyCore

@Suite("Grams in the user's number format")
struct GramsTests {
    @Test func gramsHaveNoGroupingSeparator() {
        #expect(Grams.text(590, locale: Locale(identifier: "en_US")) == "590")
        // No grouping separator in any region: "1000", as the design writes it.
        #expect(Grams.text(1000, locale: Locale(identifier: "en_US")) == "1000")
        #expect(Grams.text(1000, locale: Locale(identifier: "de_DE")) == "1000")
        #expect(Grams.text(12345, locale: Locale(identifier: "fr_FR")) == "12345")
        #expect(Grams.text(0, locale: Locale(identifier: "en_US")) == "0")
    }

    @Test func theDefaultIsTheCurrentLocale() {
        #expect(Grams.text(1000) == 1000.formatted(.number.grouping(.never)))
    }

    @Test func theFeedRowsFormatTheirGrams() throws {
        let k = Grams.text(1000)
        var spool = knownSpool()
        spool.weightUsed = 0
        let row = FeedRow(scanId: "s-1", dump: try fixtureScan().tag, spool: spool, status: .awaitingWeight)
        let item = FeedItem(row)
        #expect(item.remainingText == "\(k) g left of \(k)")
        #expect(item.watchSubText == "\(k) g left")
        #expect(item.accessibilityHeader.contains("\(k) grams left of \(k)"))
        #expect(FeedItem.readout(value: 1250, mode: .gross, core: 250).text
            == "Saves \(k) g left \u{00B7} \(Grams.text(1250)) \u{2212} 250 g core")
    }
}
