import Foundation
import Testing
@testable import FliBuddyCore

@Suite("iPad layout decision")
struct FeedLayoutTests {
    @Test func aRegularLandscapeWindowGetsTheSidebar() {
        // 13" and 11" iPads, full screen; a window as wide as it is tall is portrait.
        #expect(FeedLayout.forWindow(width: 1366, height: 1024, isCompact: false) == .sidebar)
        #expect(FeedLayout.forWindow(width: 1180, height: 820, isCompact: false) == .sidebar)
        #expect(FeedLayout.forWindow(width: 1194, height: 834, isCompact: false) == .sidebar)
        #expect(FeedLayout.forWindow(width: 800, height: 800, isCompact: false) == .tabs)
    }

    @Test func aRegularPortraitWindowGetsTheTabs() {
        #expect(FeedLayout.forWindow(width: 1024, height: 1366, isCompact: false) == .tabs)
        #expect(FeedLayout.forWindow(width: 834, height: 1194, isCompact: false) == .tabs)
        // a Stage Manager window taller than wide
        #expect(FeedLayout.forWindow(width: 700, height: 900, isCompact: false) == .tabs)
    }

    @Test func aCompactWidthIsTheIPhoneLayout() {
        #expect(FeedLayout.forWindow(width: 402, height: 874, isCompact: true) == .cards)
        // a narrow Split View or Stage Manager window, even one wider than tall
        #expect(FeedLayout.forWindow(width: 507, height: 1024, isCompact: true) == .cards)
        #expect(FeedLayout.forWindow(width: 680, height: 500, isCompact: true) == .cards)
    }

    @Test func nearASquareWindowTheLayoutKeepsWhatItHad() {
        // A dead band of 40 pt around square, so a window resized across it
        // does not flip the layout at every point.
        #expect(FeedLayout.squareDeadBand == 40)
        #expect(FeedLayout.forWindow(width: 900, height: 885, isCompact: false, previous: .tabs) == .tabs)
        #expect(FeedLayout.forWindow(width: 900, height: 879, isCompact: false, previous: .tabs) == .sidebar)
        #expect(FeedLayout.forWindow(width: 885, height: 900, isCompact: false, previous: .sidebar) == .sidebar)
        #expect(FeedLayout.forWindow(width: 879, height: 900, isCompact: false, previous: .sidebar) == .tabs)
        // full-screen iPads are far from square either way
        #expect(FeedLayout.forWindow(width: 1366, height: 1024, isCompact: false, previous: .tabs) == .sidebar)
        #expect(FeedLayout.forWindow(width: 1024, height: 1366, isCompact: false, previous: .sidebar) == .tabs)
        // from the cards (or nothing yet) the plain rule applies, and compact always wins
        #expect(FeedLayout.forWindow(width: 900, height: 885, isCompact: false, previous: .cards) == .sidebar)
        #expect(FeedLayout.forWindow(width: 900, height: 885, isCompact: false, previous: nil) == .sidebar)
        #expect(FeedLayout.forWindow(width: 900, height: 600, isCompact: true, previous: .sidebar) == .cards)
    }

    @Test func theWindowIsTheViewWithItsSafeAreasAndTheKeyboard() {
        // Simulator, 13" portrait: SwiftUI reports 1032 × 1324 inside the
        // safe areas, and 1032 × 941 with the keyboard up (its height is a
        // bottom inset). Either way the window is 1032 × 1376: portrait.
        let plain = FeedLayout.windowSize(width: 1032, height: 1324, top: 24, bottom: 28, leading: 0, trailing: 0)
        #expect(plain == FeedLayout.Size(width: 1032, height: 1376))
        let keyboard = FeedLayout.windowSize(width: 1032, height: 941, top: 24, bottom: 411, leading: 0, trailing: 0)
        #expect(keyboard == FeedLayout.Size(width: 1032, height: 1376))
        #expect(FeedLayout.forWindow(width: keyboard.width, height: keyboard.height, isCompact: false, previous: .tabs) == .tabs)
        // side insets count too
        #expect(FeedLayout.windowSize(width: 1300, height: 1000, top: 24, bottom: 0, leading: 38, trailing: 38).width == 1376)
    }

    @Test func whatEachLayoutShows() {
        #expect(FeedLayout.sidebar.hasSidebar)
        #expect(!FeedLayout.tabs.hasSidebar)
        #expect(!FeedLayout.cards.hasSidebar)
        // the iPad page draws tiles in both orientations
        #expect(FeedLayout.sidebar.showsTiles)
        #expect(FeedLayout.tabs.showsTiles)
        #expect(!FeedLayout.cards.showsTiles)
        // beside the sidebar its status rows and Clear feed take the banner's and the toolbar's place
        #expect(!FeedLayout.sidebar.showsBanner)
        #expect(FeedLayout.tabs.showsBanner)
        #expect(FeedLayout.cards.showsBanner)
        // the iPhone's bottom tab bar gives the number pad its room; the iPad's top one stays
        #expect(FeedLayout.cards.hidesTabBarWhileTyping)
        #expect(!FeedLayout.tabs.hidesTabBarWhileTyping)
        // the iPad asks "Clear the feed?" in a centred alert, the iPhone in an action sheet
        #expect(FeedLayout.sidebar.centresClearConfirmation)
        #expect(FeedLayout.tabs.centresClearConfirmation)
        #expect(!FeedLayout.cards.centresClearConfirmation)
        // a spool opens in the inspector beside the sidebar, in a sheet otherwise
        #expect(FeedLayout.sidebar.opensSpoolInInspector)
        #expect(!FeedLayout.tabs.opensSpoolInInspector)
        #expect(!FeedLayout.cards.opensSpoolInInspector)
        #expect(FeedLayout.inspectorWidth == 320)
        // the Spools scope control never stretches across a wide grid
        #expect(FeedLayout.scopeMaximumWidth == 300)
    }

    /// The tile grid's width: the detail column less the 28 pt side margins.
    private func grid(_ detail: Double) -> Int {
        FeedLayout.tileColumns(width: detail - 2 * FeedLayout.tileMargin)
    }

    @Test func tilesAreAtLeast300WideAndAtMostThreeToARow() {
        #expect(FeedLayout.tileMinimumWidth == 300)
        #expect(FeedLayout.tileSpacing == 12)
        #expect(FeedLayout.tileMargin == 28)
        // 13" iPad: landscape beside the sidebar and portrait both fit three
        #expect(grid(1366 - FeedLayout.sidebarWidth) == 3)
        #expect(grid(1376 - FeedLayout.sidebarWidth) == 3)
        #expect(grid(1024) == 3)
        #expect(grid(1032) == 3)
        // 11" iPad: two, in landscape beside the sidebar and in portrait
        #expect(grid(1180 - FeedLayout.sidebarWidth) == 2)
        #expect(grid(1210 - FeedLayout.sidebarWidth) == 2)
        #expect(grid(820) == 2)
        #expect(grid(834) == 2)
        // a wide external display keeps three; a narrow window one
        #expect(FeedLayout.tileColumns(width: 2400) == 3)
        #expect(FeedLayout.tileColumns(width: 611) == 1)
        #expect(FeedLayout.tileColumns(width: 612) == 2)
        #expect(FeedLayout.tileColumns(width: 0) == 1)
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

    private func serverLine(_ item: StatusItem, url: String = "http://bambuddy.local:8000") -> String? {
        sidebar(bambuddy: item, url: url).bambuddy.server
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
        #expect(nearby.subline == "Flipper not connected")
        #expect(nearby.symbol == "antenna.radiowaves.left.and.right")
        #expect(nearby.tint == .orange)
        #expect(nearby.action == .settings)
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

    @Test func readyNamesTheServersHostOnItsOwnLine() {
        // "Ready · bambuddy.example.com" wrapped awkwardly in the ~300 pt sidebar.
        let row = sidebar().bambuddy
        #expect(
            row == Sidebar.StatusRow(
                name: "Bambuddy", subline: "Ready", symbol: "server.rack", tint: .green,
                spins: false, isSublineRed: false, action: nil, detail: nil, server: "bambuddy.local"
            )
        )
        let ready = BambuddyState.ready.statusItem()
        #expect(serverLine(ready, url: "192.168.1.20:8000") == "192.168.1.20")
        #expect(serverLine(ready, url: " https://inventory.example.com/ ") == "inventory.example.com")
        #expect(serverLine(ready, url: "") == nil)
        // Only a ready Bambuddy names it.
        #expect(serverLine(BambuddyState.unreachable("x").statusItem()) == nil)
    }

    @Test func everyBambuddyPhraseLosesItsPrefixAndIsCapitalised() {
        let cases: [(StatusItem, String)] = [
            (BambuddyState.unchecked.statusItem(), "Not checked"),
            (BambuddyState.notConfigured.statusItem(), "Not set up"),
            (BambuddyState.unreachable("timed out").statusItem(), "Unreachable"),
            (BambuddyState.refused(.permissionMissing("inventory:read")).statusItem(), "API key lacks inventory permission"),
            (BambuddyState.refused(.unauthorized).statusItem(), "Rejected the API key"),
            (BambuddyState.refused(.spoolmanMode).statusItem(), "In Spoolman mode"),
            (BambuddyState.ready.statusItem(colorNamesProblem: "HTTP 500"), "Ready \u{00B7} color names unavailable"),
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

    @Test func spoolsCountsTheActiveSpoolsOnceLoaded() {
        #expect(sidebar().spoolCount == nil)
        let loaded = Sidebar(
            flipper: flipper(.connected(Self.fap)), bambuddy: BambuddyState.ready.statusItem(), flipperName: nil,
            serverURL: "", feedCount: 0, spoolCount: 7
        )
        #expect(loaded.spoolCount == 7)
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
                serverURL: settings.baseURL, feedCount: 0, spoolCount: nil
            )
        )
        #expect(host.sidebar.flipper.action == .settings)
        #expect(!host.sidebar.canClear)
    }
}
