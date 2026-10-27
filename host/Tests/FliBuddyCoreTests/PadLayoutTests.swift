import Foundation
import Testing
@testable import FliBuddyCore

@Suite("iPad layout decision")
struct FeedLayoutTests {
    @Test func theTableNeedsA900PointDetailColumnBesideTheSidebar() {
        #expect(FeedLayout.sidebarWidth == 300)
        #expect(FeedLayout.minimumTableWidth == 900)
        #expect(FeedLayout.forWindow(width: 1199, isCompact: false) == .cards)
        #expect(FeedLayout.forWindow(width: 1200, isCompact: false) == .table)
    }

    @Test func landscapeGetsTheTablePortraitTheCards() {
        // 12.9" / 13" iPad
        #expect(FeedLayout.forWindow(width: 1366, isCompact: false) == .table)
        #expect(FeedLayout.forWindow(width: 1024, isCompact: false) == .cards)
        // 11" iPad landscape leaves under 900 beside the sidebar
        #expect(FeedLayout.forWindow(width: 1194, isCompact: false) == .cards)
    }

    @Test func aCompactWidthIsAlwaysTheCards() {
        #expect(FeedLayout.forWindow(width: 402, isCompact: true) == .cards)
        // a wide window that still reports compact (iPhone Pro Max landscape)
        #expect(FeedLayout.forWindow(width: 1366, isCompact: true) == .cards)
    }
}

@MainActor
@Suite("iPad sidebar")
struct SidebarTests {
    private static let fap = Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1")

    private func flipper(_ state: LinkState, problem: String? = nil, isActive: Bool = true) -> StatusItem {
        FlipperLink.statusItem(
            state, choice: .bluetooth(peripheral: nil), port: nil, problem: problem, isActive: isActive
        )
    }

    private func sidebar(
        flipper item: StatusItem? = nil, bambuddy: StatusItem = BambuddyState.ready.statusItem(),
        name: String? = "Workshop", url: String = "http://bambuddy.local:8000", count: Int = 0
    ) -> Sidebar {
        Sidebar(
            flipper: item ?? flipper(.connected(Self.fap)), bambuddy: bambuddy, flipperName: name, serverURL: url,
            feedCount: count
        )
    }

    private func bambuddyLine(_ item: StatusItem, url: String = "http://bambuddy.local:8000") -> String {
        sidebar(bambuddy: item, url: url).bambuddy.subline
    }

    // MARK: Flipper row

    @Test func aConnectedFlipperShowsItsName() {
        let row = sidebar().flipper
        #expect(
            row == Sidebar.StatusRow(
                name: "Flipper", subline: "Workshop \u{00B7} Bluetooth", symbol: "antenna.radiowaves.left.and.right",
                tint: .green, spins: false, isSublineRed: false, action: nil, detail: "firmware 1.5.1"
            )
        )
        // no name saved: the phrase as it is
        #expect(sidebar(name: nil).flipper.subline == "Flipper \u{00B7} Bluetooth")
        #expect(sidebar(name: "").flipper.subline == "Flipper \u{00B7} Bluetooth")
    }

    @Test func searchingSpinsBesideTheSlashedAntenna() {
        let row = sidebar(flipper: flipper(.disconnected)).flipper
        #expect(row.subline == "No Flipper \u{00B7} searching")
        #expect(row.symbol == "antenna.radiowaves.left.and.right.slash")
        #expect(row.spins)
        #expect(row.tint == .gray)
        #expect(row.action == nil)
        #expect(sidebar(flipper: flipper(.waitingForHello)).flipper.spins)
    }

    @Test func theOtherFlipperStatesKeepTheirPhraseAndAction() {
        let nearby = sidebar(flipper: flipper(.disconnected, isActive: false)).flipper
        #expect(nearby.subline == "Flipper nearby, not connected")
        #expect(nearby.symbol == "antenna.radiowaves.left.and.right")
        #expect(nearby.tint == .orange)
        #expect(nearby.action == .connect)
        let noApp = sidebar(flipper: flipper(.noAnswer)).flipper
        #expect(noApp.subline == "Open FliBuddy on the Flipper")
        #expect(noApp.symbol == "app.dashed")
        #expect(!noApp.spins)
        // a reason the link is down, shown as it is
        let off = sidebar(flipper: flipper(.disconnected, problem: "Bluetooth is off")).flipper
        #expect(off.subline == "Bluetooth is off")
        #expect(!off.isSublineRed)
        // the Flipper's name is only for a connected Flipper
        #expect(!sidebar(flipper: flipper(.otherVersion(9))).flipper.subline.contains("Workshop"))
    }

    // MARK: Bambuddy row

    @Test func readyNamesTheServersHost() {
        let row = sidebar().bambuddy
        #expect(
            row == Sidebar.StatusRow(
                name: "Bambuddy", subline: "Ready \u{00B7} bambuddy.local", symbol: "server.rack", tint: .green,
                spins: false, isSublineRed: false, action: nil, detail: nil
            )
        )
        let ready = BambuddyState.ready.statusItem()
        #expect(bambuddyLine(ready, url: "192.168.1.20:8000") == "Ready \u{00B7} 192.168.1.20")
        #expect(bambuddyLine(ready, url: " https://inventory.example.com/ ") == "Ready \u{00B7} inventory.example.com")
        #expect(bambuddyLine(ready, url: "") == "Ready")
    }

    @Test func everyBambuddyPhraseLosesItsPrefixAndIsCapitalised() {
        let cases: [(StatusItem, String)] = [
            (BambuddyState.unchecked.statusItem(), "Not checked"),
            (BambuddyState.notConfigured.statusItem(), "Not set up"),
            (BambuddyState.unreachable("timed out").statusItem(), "Unreachable"),
            (BambuddyState.refused(.permissionMissing("inventory:read")).statusItem(), "API key lacks inventory permission"),
            (BambuddyState.refused(.unauthorized).statusItem(), "Rejected the API key"),
            (BambuddyState.refused(.spoolmanMode).statusItem(), "In Spoolman mode"),
            (BambuddyState.ready.statusItem(colorNamesProblem: "HTTP 500"), "Ready \u{00B7} colour names unavailable"),
            (BambuddyState.ready.statusItem(isChecking: true), "Checking\u{2026}"),
        ]
        for (item, text) in cases {
            #expect(bambuddyLine(item) == text)
        }
    }

    @Test func aRedBambuddyStateTurnsTheSubLineRed() {
        let unreachable = sidebar(bambuddy: BambuddyState.unreachable("timed out").statusItem()).bambuddy
        #expect(unreachable.isSublineRed)
        #expect(unreachable.symbol == "wifi.exclamationmark")
        #expect(unreachable.action == .retry)
        #expect(unreachable.detail == "timed out")
        #expect(sidebar(bambuddy: BambuddyState.refused(.permissionMissing("inventory:read")).statusItem()).bambuddy.action == .settings)
        #expect(!sidebar(bambuddy: BambuddyState.unchecked.statusItem()).bambuddy.isSublineRed)
        #expect(sidebar(bambuddy: BambuddyState.unchecked.statusItem()).bambuddy.action == .check)
    }

    @Test func checkingSpinsBesideTheServerSymbol() {
        let row = sidebar(bambuddy: BambuddyState.ready.statusItem(isChecking: true)).bambuddy
        #expect(row.symbol == "server.rack")
        #expect(row.spins)
    }

    // MARK: Feed, Settings, Clear

    @Test func feedCountsItsRowsAndClearNeedsOne() {
        #expect(sidebar(count: 3).feedCount == 3)
        #expect(sidebar(count: 3).canClear)
        #expect(!sidebar(count: 0).canClear)
        #expect(Sidebar.connectionsTitle == "Connections")
        #expect(Sidebar.clearTitle == "Clear feed")
        #expect(Sidebar.settingsHint == "\u{2318},")
        #expect(Sidebar.clearHint == "\u{2318}\u{232B}")
    }

    @Test func theHostBuildsItFromItsState() throws {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        var settings = testSettings
        settings.peripheralName = "Workshop"
        try store.save(settings)
        let host = HostModel(store: store, makeInventory: { _ in FakeInventory() }, makeTransport: { _ in FakeTransport() })
        #expect(
            host.sidebar == Sidebar(
                flipper: host.link.statusItem, bambuddy: host.feed.bambuddyStatus, flipperName: "Workshop",
                serverURL: settings.baseURL, feedCount: 0
            )
        )
        #expect(host.sidebar.flipper.action == .connect)
        #expect(!host.sidebar.canClear)
    }
}
