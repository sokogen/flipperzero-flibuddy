import Foundation
import Testing
@testable import FliBuddyCore

private func row(
    _ name: String = "scan_mfc", status: FeedRow.Status, spool: Spool? = knownSpool(),
    request: FeedRow.HostRequest? = nil
) throws -> FeedRow {
    var row = FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: status)
    row.request = request
    return row
}

private func screen(_ row: FeedRow, isCreating: Bool = false) -> WatchRowScreen {
    WatchRowScreen(FeedItem(row), isCreating: isCreating)
}

@Suite("Watch row detail screen")
struct WatchRowScreenTests {
    @Test func aKnownSpoolWaitingForAWeightIsTheEntry() throws {
        for status in [FeedRow.Status.awaitingWeight, .saving, .updating, .error("timed out")] {
            #expect(screen(try row(status: status)) == .entry(offersNew: false))
        }
    }

    /// The spool exists: New is never offered again.
    @Test func aCreatedRowOffersNoNew() throws {
        #expect(screen(try row(status: .created)) == .unknown(hint: nil, offersNew: false))
    }

    @Test func aNewSpoolOffersNew() throws {
        #expect(screen(try row(status: .unknown(prefill: true), spool: nil)) == .unknown(hint: nil, offersNew: true))
    }

    @Test func aBambuTagSavingItsNewSpoolIsBusy() throws {
        let saving = try row(status: .saving, spool: nil)
        #expect(screen(saving) == .busy("Saving\u{2026}"))
    }

    @Test func newOnTheWatchShowsBusyUntilTheSpoolExists() throws {
        let unknown = try row(status: .unknown(prefill: true), spool: nil)
        #expect(screen(unknown, isCreating: true) == .busy(WatchRowScreen.creatingText))
        #expect(WatchRowScreen.creatingText == "Creating in Bambuddy\u{2026}")
    }

    @Test func savedAndMarkedRowsShowTheResult() throws {
        for status in [FeedRow.Status.saved, .savedAfterTimeout, .markedNew, .markedEmpty] {
            #expect(screen(try row(status: status)) == .saved)
        }
    }

    @Test func lookingUpIsBusy() throws {
        #expect(screen(try row(status: .scanned, spool: nil)) == .busy("Looking up"))
    }

    @Test func aTagWithoutMaterialIsCreatedOnThePhoneOrMac() throws {
        let unknown = try row("scan_ntag", status: .unknown(prefill: false), spool: nil)
        #expect(screen(unknown) == .unknown(hint: "Create it on iPhone or Mac.", offersNew: false))
    }

    @Test func aLinkRequestIsLinkedOnThePhoneOrMac() throws {
        let asks = try row("scan_ntag", status: .unknown(prefill: false), spool: nil, request: .link)
        #expect(screen(asks) == .unknown(hint: "Link it on iPhone or Mac.", offersNew: false))
    }

    @Test func aCreateRequestForATagWithoutMaterialHintsCreate() throws {
        let asks = try row("scan_ntag", status: .unknown(prefill: false), spool: nil, request: .create)
        #expect(screen(asks) == .unknown(hint: "Create it on iPhone or Mac.", offersNew: false))
    }

    @Test func aDeletedSpoolHasNoHintAndOffersNewForATagWithMaterial() throws {
        #expect(screen(try row(status: .deleted, spool: nil)) == .unknown(hint: nil, offersNew: true))
        let blank = try row("scan_ntag", status: .deleted, spool: nil)
        #expect(screen(blank) == .unknown(hint: nil, offersNew: false))
    }

    @Test func aFailedCreateForATagWithoutMaterialStaysUnknown() throws {
        let failed = try row("scan_ntag", status: .error("Bambuddy said no"), spool: nil)
        #expect(screen(failed) == .unknown(hint: "Create it on iPhone or Mac.", offersNew: false))
    }
}

@Suite("Watch entry line")
struct WatchEntryLineTests {
    private func item(_ status: FeedRow.Status = .awaitingWeight) throws -> FeedItem {
        FeedItem(try row(status: status))
    }

    @Test func netSaysWhatASaveRecords() throws {
        let line = WatchRowScreen.entryLine(try item(), value: 590, mode: .net, hostError: nil)
        #expect(line == FeedItem.Readout(text: "Saves 590 g left", isError: false))
    }

    @Test func grossDropsTheSumToFitOneLine() throws {
        // knownSpool's core weight is 250 g.
        let line = WatchRowScreen.entryLine(try item(), value: 840, mode: .gross, hostError: nil)
        #expect(line == FeedItem.Readout(text: "Saves 590 g left", isError: false))
    }

    @Test func belowTheCoreIsRed() throws {
        let line = WatchRowScreen.entryLine(try item(), value: 100, mode: .gross, hostError: nil)
        #expect(line == FeedItem.Readout(text: "Below the core weight (250 g)", isError: true))
    }

    @Test func noValueAsksForTheCrown() throws {
        let line = WatchRowScreen.entryLine(try item(), value: nil, mode: .net, hostError: nil)
        #expect(line == FeedItem.Readout(text: "Turn the crown", isError: false))
    }

    @Test func anErrorRowShowsItsError() throws {
        let line = WatchRowScreen.entryLine(try item(.error("timed out")), value: 590, mode: .net, hostError: nil)
        #expect(line == FeedItem.Readout(text: "Error: timed out", isError: true))
    }

    @Test func aHostErrorWins() throws {
        let line = WatchRowScreen.entryLine(
            try item(.error("timed out")), value: 590, mode: .net, hostError: "Bambuddy unreachable"
        )
        #expect(line == FeedItem.Readout(text: "Error: Bambuddy unreachable", isError: true))
    }

    @Test func theSavedScreenShowsTheGramsLeft() throws {
        #expect(WatchRowScreen.remainingText(try item(.saved)) == "484 g")
        #expect(WatchRowScreen.remainingText(FeedItem(try row("scan_ntag", status: .deleted, spool: nil))) == nil)
    }
}

@Suite("Watch details")
struct WatchDetailsTests {
    @Test func listsOnlyTheWatchFactsInTheSpecOrder() throws {
        let details = TagDetails(try row(status: .saved))
        let labels = details.watchFacts.map(\.label)
        let order = ["Colour", "Colour code", "UID", "Filament ID", "Diameter", "Nozzle", "Spool"]
        #expect(labels == order.filter { details.value($0) != nil })
        #expect(labels.contains("UID"))
        #expect(!labels.contains("RGBA"))
        #expect(!labels.contains("Tray UUID"))
    }
}

@Suite("Watch settings texts")
struct WatchSettingsTextsTests {
    @Test(arguments: [
        ("http://bambuddy.local:8000", "bambuddy.local:8000"),
        ("https://bambuddy.example.com", "bambuddy.example.com"),
        ("http://192.168.1.20:8000/", "192.168.1.20:8000"),
        ("", "Not set"),
        ("not a url", "not a url"),
    ])
    func theServerIsHostAndPort(_ url: String, _ server: String) {
        #expect(WatchSettingsTexts.server(url) == server)
    }

    @Test func coreAndMode() {
        #expect(WatchSettingsTexts.coreWeight(325) == "325 g")
        #expect(WatchSettingsTexts.mode(.gross) == "Gross")
        #expect(WatchSettingsTexts.mode(.net) == "Net")
    }

    @Test(arguments: [
        (0.0, "Received just now. Change these on iPhone."),
        (59.0, "Received just now. Change these on iPhone."),
        (60.0, "Received 1 min ago. Change these on iPhone."),
        (150.0, "Received 2 min ago. Change these on iPhone."),
        (3600.0, "Received 1 h ago. Change these on iPhone."),
        (86_400.0 * 3, "Received 3 d ago. Change these on iPhone."),
        (-30.0, "Received just now. Change these on iPhone."),
    ])
    func theFooterSaysWhenSettingsArrived(_ age: Double, _ footer: String) {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(WatchSettingsTexts.footer(received: now.addingTimeInterval(-age), now: now) == footer)
    }

    @Test func withoutAReceiptTheFooterOnlyPointsToTheIPhone() {
        #expect(WatchSettingsTexts.footer(received: nil, now: .now) == "Change these on iPhone.")
    }

    @Test func theEmptyTextNoLongerAsksForASave() {
        #expect(WatchSettingsTexts.emptyText == "Open FliBuddy on the iPhone to send its settings.")
    }

    @Test(arguments: [(-40, "Nearby \u{00B7} strong"), (-60, "Nearby \u{00B7} strong"), (-61, "Nearby"), (-95, "Nearby")])
    func signalWords(_ rssi: Int, _ words: String) {
        #expect(WatchSettingsTexts.signal(rssi: rssi) == words)
    }
}

@MainActor
@Suite("Watch Flipper platter")
struct WatchFlipperPlatterTests {
    private static let fap = Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1")

    private func flipper(_ state: LinkState, isActive: Bool = true) -> StatusItem {
        WatchSettingsTexts.flipperStatus(FlipperLink.statusItem(
            state, choice: .bluetooth(peripheral: nil), port: nil, problem: nil, isActive: isActive
        ))
    }

    @Test func connectedIsAGreenConnected() {
        let status = flipper(.connected(Self.fap))
        #expect(status.text == "Connected")
        #expect(status.symbol == .symbol("antenna.radiowaves.left.and.right"))
        #expect(status.tint == .green)
    }

    @Test func nearbyDropsTheFlipperPrefix() {
        let status = flipper(.disconnected, isActive: false)
        #expect(status.text == "nearby")
        #expect(status.tint == .orange)
    }

    @Test func searchingKeepsItsPhrase() {
        let status = flipper(.disconnected)
        #expect(status.text == "No Flipper \u{00B7} searching")
        #expect(status.symbol == .progress)
    }

    @Test func noHelloKeepsItsPhrase() {
        #expect(flipper(.noAnswer).text == "Open FliBuddy on the Flipper")
    }

    @Test func theNameFallsBackToFlipper() {
        #expect(WatchSettingsTexts.flipperName("Workshop") == "Workshop")
        #expect(WatchSettingsTexts.flipperName(nil) == "Flipper")
        #expect(WatchSettingsTexts.flipperName("") == "Flipper")
    }
}

@Suite("Watch scan screen navigation")
struct WatchScanNavigationTests {
    let id = UUID()

    private func rows(_ waiting: Bool) -> [WatchNavigation.Row] {
        [WatchNavigation.Row(id: id, isWaiting: waiting)]
    }

    @Test func scanOpensOverSettingsAndClosesBackToIt() {
        var navigation = WatchNavigation()
        navigation.openSettings()
        navigation.openScan()
        #expect(navigation.path == [.settings, .scan])
        navigation.closeScan()
        #expect(navigation.path == [.settings])
    }

    @Test func nothingAutoOpensOverTheScanScreen() {
        var navigation = WatchNavigation(path: [.settings, .scan], rows: rows(false))
        navigation.update(rows: rows(true))
        #expect(navigation.path == [.settings, .scan])
    }

    @Test func closeScanLeavesAnotherScreenAlone() {
        var navigation = WatchNavigation(path: [.settings])
        navigation.closeScan()
        #expect(navigation.path == [.settings])
    }
}
