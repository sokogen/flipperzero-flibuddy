import Foundation
import Testing
@testable import FliBuddyCore

private func row(
    _ name: String = "scan_mfc", status: FeedRow.Status, spool: Spool? = knownSpool()
) throws -> FeedRow {
    FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: status)
}

private func scan(_ scanId: String) throws -> Scan {
    var scan = try fixtureScan()
    scan.scanId = scanId
    return scan
}

@Suite("Watch feed row texts")
struct WatchFeedRowTests {
    @Test func aKnownSpoolSaysWhatIsLeft() throws {
        let item = FeedItem(try row(status: .awaitingWeight))
        #expect(item.watchTitle == "PLA Basic")
        #expect(item.watchSubText == "484 g left")
    }

    @Test func anArchivedSpoolSaysArchived() throws {
        var spool = knownSpool(weightUsed: 1000)
        spool.archived = true
        #expect(FeedItem(try row(status: .markedEmpty, spool: spool)).watchSubText == "archived")
    }

    @Test func aTagWithMaterialShowsItsLabelWeight() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true), spool: nil))
        #expect(item.watchTitle == item.title)
        #expect(item.watchSubText == "label 1000 g")
    }

    @Test func aTagWithoutMaterialIsAnUnknownTagWithAShortTitle() throws {
        let item = FeedItem(try row("scan_ntag", status: .unknown(prefill: false), spool: nil))
        #expect(item.watchTitle == "NTAG 0411\u{2026}")
        #expect(item.watchSubText == "Unknown tag")
        #expect(FeedItem.shortBlankTitle(uid: "04A2B3C4") == "NTAG 04A2\u{2026}")
        #expect(FeedItem.shortBlankTitle(uid: "04A2") == "NTAG 04A2")
    }
}

@MainActor
@Suite("Watch connection glyph")
struct WatchGlyphTests {
    private static let fap = Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1")

    private func flipper(_ state: LinkState, isActive: Bool = true) -> StatusItem {
        FlipperLink.statusItem(
            state, choice: .bluetooth(peripheral: nil), port: nil, problem: nil, isActive: isActive
        )
    }

    private var connected: StatusItem { flipper(.connected(Self.fap)) }
    private var ready: StatusItem { BambuddyState.ready.statusItem() }

    @Test func bothHealthyIsTheGreenAntenna() {
        let glyph = WatchGlyph.status(flipper: connected, bambuddy: ready)
        #expect(glyph.text == "Flipper connected")
        #expect(glyph.symbol == .symbol("antenna.radiowaves.left.and.right"))
        #expect(glyph.tint == .green)
    }

    @Test func theFlipperProblemWinsOverBambuddys() {
        let unreachable = BambuddyState.unreachable("timed out").statusItem()
        let searching = WatchGlyph.status(flipper: flipper(.disconnected), bambuddy: unreachable)
        #expect(searching.text == "No Flipper \u{00B7} searching")
        #expect(searching.symbol == .progress)
        #expect(searching.tint == .gray)
    }

    @Test func eachRowOfTheSpecTable() {
        let cases: [(StatusItem, StatusItem, String, StatusSymbol, StatusTint)] = [
            (flipper(.disconnected, isActive: false), ready, "Flipper nearby",
             .symbol("antenna.radiowaves.left.and.right"), .orange),
            (flipper(.noAnswer), ready, "Open FliBuddy on the Flipper", .symbol("app.dashed"), .orange),
            (connected, BambuddyState.unchecked.statusItem(), "Bambuddy not checked", .symbol("server.rack"), .gray),
            (connected, BambuddyState.unreachable("x").statusItem(), "Bambuddy unreachable",
             .symbol("wifi.exclamationmark"), .red),
            (connected, BambuddyState.refused(.permissionMissing("no inventory:write")).statusItem(), "Key lacks inventory permission",
             .symbol("lock.trianglebadge.exclamationmark"), .red),
            (connected, BambuddyState.refused(.spoolmanMode).statusItem(), "Bambuddy is in Spoolman mode",
             .symbol("nosign"), .red),
            (connected, BambuddyState.ready.statusItem(colorNamesProblem: "404"), "Colour names unavailable",
             .symbol("paintpalette"), .orange),
        ]
        for (flipper, bambuddy, text, symbol, tint) in cases {
            let glyph = WatchGlyph.status(flipper: flipper, bambuddy: bambuddy)
            #expect(glyph.text == text)
            #expect(glyph.symbol == symbol, "\(text)")
            #expect(glyph.tint == tint, "\(text)")
            #expect(glyph.short == nil, "\(text)")
        }
    }
}

@Suite("Watch navigation: auto-open and pop")
struct WatchNavigationTests {
    let a = UUID(), b = UUID(), c = UUID()
    private typealias Row = WatchNavigation.Row

    @Test func aRowThatStartsWaitingOpensWhileTheFeedShows() {
        var navigation = WatchNavigation(rows: [Row(id: a, isWaiting: false)])

        navigation.update(rows: [Row(id: b, isWaiting: true), Row(id: a, isWaiting: false)])

        #expect(navigation.path == [.row(b)])
    }

    @Test func aRescanOrReopenOpensTheRowAgain() {
        var navigation = WatchNavigation(rows: [Row(id: a, isWaiting: false)])

        navigation.update(rows: [Row(id: a, isWaiting: true)])

        #expect(navigation.path == [.row(a)])
    }

    @Test func theNewestOfSeveralStartedRowsOpens() {
        var navigation = WatchNavigation()

        navigation.update(rows: [Row(id: c, isWaiting: true), Row(id: b, isWaiting: true)])

        #expect(navigation.path == [.row(c)])
    }

    @Test func nothingOpensOverADetailOrSettings() {
        var detail = WatchNavigation(path: [.row(a)], rows: [Row(id: a, isWaiting: true)])
        detail.update(rows: [Row(id: b, isWaiting: true), Row(id: a, isWaiting: true)])
        #expect(detail.path == [.row(a)])

        var settings = WatchNavigation(path: [.settings])
        settings.update(rows: [Row(id: b, isWaiting: true)])
        #expect(settings.path == [.settings])
        // back on the feed, the missed row does not open later
        settings.path = []
        settings.update(rows: [Row(id: b, isWaiting: true)])
        #expect(settings.path.isEmpty)
    }

    @Test func aRowStillWaitingOrNotWaitingDoesNotOpen() {
        var navigation = WatchNavigation(rows: [Row(id: a, isWaiting: true)])

        navigation.update(rows: [Row(id: a, isWaiting: true), Row(id: b, isWaiting: false)])

        #expect(navigation.path.isEmpty)
    }

    @Test func aSavedDetailPopsBackToTheFeed() {
        var navigation = WatchNavigation(path: [.row(a)], rows: [Row(id: a, isWaiting: false)])

        navigation.popAfterSave(a)

        #expect(navigation.path.isEmpty)
        #expect(WatchNavigation.popDelay == .seconds(1))
    }

    @Test func afterThePopTheNewestWaitingRowOpens() {
        var navigation = WatchNavigation(path: [.row(a)], rows: [Row(id: a, isWaiting: false)])
        // a scan while the saved detail still shows opens nothing yet
        navigation.update(rows: [Row(id: b, isWaiting: true), Row(id: a, isWaiting: false)])
        #expect(navigation.path == [.row(a)])

        navigation.popAfterSave(a)

        #expect(navigation.path == [.row(b)])
    }

    @Test func aRowWeighedAgainIsNotPopped() {
        var navigation = WatchNavigation(path: [.row(a)], rows: [Row(id: a, isWaiting: true)])

        navigation.popAfterSave(a)

        #expect(navigation.path == [.row(a)])
    }

    @Test func thePopLeavesAnotherScreenAlone() {
        var settings = WatchNavigation(path: [.settings], rows: [Row(id: b, isWaiting: true)])
        settings.popAfterSave(a)
        #expect(settings.path == [.settings])

        var other = WatchNavigation(path: [.row(c)], rows: [Row(id: b, isWaiting: true)])
        other.popAfterSave(a)
        #expect(other.path == [.row(c)])
    }

    @Test func backBeforeThePopStillOpensTheWaitingRow() {
        var navigation = WatchNavigation(rows: [Row(id: b, isWaiting: true), Row(id: a, isWaiting: false)])

        navigation.popAfterSave(a)

        #expect(navigation.path == [.row(b)])
    }

    @Test func tapsOpenARowOrSettings() {
        var navigation = WatchNavigation()
        navigation.open(a)
        #expect(navigation.path == [.row(a)])
        navigation.openSettings()
        #expect(navigation.path == [.settings])
    }

    /// The feed model drives it: a scan and lookup start the wait, the
    /// save reports success, and the next scan's row opens after the pop.
    @MainActor
    @Test func followsTheFeed() async throws {
        let session = Session(settings: testSettings, inventory: FakeInventory(spools: [knownSpool()]))
        let feed = FeedViewModel(session: session, settings: testSettings)
        var navigation = WatchNavigation()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        feed.apply(await session.snapshot)
        navigation.update(feed.items)
        #expect(navigation.path == [.row(id)])

        feed.setWeightText("734", for: id)
        #expect(await feed.save(id))
        navigation.update(feed.items)
        navigation.popAfterSave(id)
        #expect(navigation.path.isEmpty)
    }

    /// The view seeds the navigation from the feed it appears with: a row
    /// that already waits then does not open on the next snapshot.
    @MainActor
    @Test func rowsWaitingAtTheStartDoNotOpen() async throws {
        let session = Session(settings: testSettings, inventory: FakeInventory(spools: [knownSpool()]))
        let feed = FeedViewModel(session: session, settings: testSettings)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        feed.apply(await session.snapshot)
        #expect(feed.items.first?.isWaiting == true)

        var navigation = WatchNavigation(feed.items)
        navigation.update(feed.items)

        #expect(navigation.path.isEmpty)
    }

    @MainActor
    @Test func aFailedSaveReportsFalse() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = Session(settings: testSettings, inventory: inventory)
        let feed = FeedViewModel(session: session, settings: testSettings)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        feed.apply(await session.snapshot)
        inventory.updateError = .network("timed out")
        feed.setWeightText("734", for: id)

        #expect(await feed.save(id) == false)
        // nothing to save at all
        #expect(await feed.save(UUID()) == false)
    }
}
