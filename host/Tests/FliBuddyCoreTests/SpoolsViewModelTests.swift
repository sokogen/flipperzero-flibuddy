import Foundation
import Testing
@testable import FliBuddyCore

/// 10:42 UTC on the day of the fixtures; the tests' clock stands still here.
private let testNow = Date(timeIntervalSince1970: 1_793_875_320) // 2026-11-05T10:42:00Z
private let utc = TimeZone(identifier: "UTC")!

private func ago(_ seconds: TimeInterval) -> String {
    BambuddyDate.string(from: testNow.addingTimeInterval(-seconds))
}

private let day: TimeInterval = 86_400

/// A spool as Bambuddy lists it, `left` grams of `label` remaining, updated `updated` seconds ago.
private func spool(
    _ id: Int, _ material: String, _ subtype: String? = nil, color: String? = nil, brand: String? = "Bambu Lab",
    label: Int = 1000, left: Int, updated: TimeInterval? = day, tag: String? = nil, note: String? = nil,
    archived: String? = nil, catalog: Int? = nil, lastScale: Int? = nil
) -> Spool {
    var spool = Spool(
        id: id, material: material, subtype: subtype, colorName: color, rgba: "3B3B3BFF", brand: brand,
        labelWeight: label, coreWeight: 242, coreWeightCatalogId: catalog, weightUsed: Double(label - left),
        lastScaleWeight: lastScale, tagUid: tag, note: note, archivedAt: archived
    )
    spool.updatedAt = updated.map(ago)
    return spool
}

/// The design's inventory (`INV` in flibuddy-core.js), archived spools included.
private func inventorySpools() -> [Spool] {
    [
        spool(14, "PETG", "HF", color: "Black", left: 742, updated: 2 * day, tag: "5B21C0DE00000100"),
        spool(21, "PLA", "Matte", color: "Charcoal", left: 410, updated: 3 * day, tag: "A1C3770E00000100",
              catalog: 1, lastScale: 652),
        spool(27, "PETG", color: "Transparent Blue", brand: "Sunlu", left: 880, updated: 21 * day, note: "drawer 3"),
        spool(30, "PLA", "Silk", color: "Copper", brand: "eSun", left: 655, updated: 12 * day,
              note: "opened in September"),
        spool(31, "TPU", "95A", color: "Red", brand: "Overture", label: 500, left: 420, updated: 35 * day),
        spool(33, "ASA", color: "White", brand: "Polymaker", left: 990, updated: nil, tag: "C07A4411"),
        spool(12, "PLA", "Basic", color: "Pumpkin Orange", left: 15, updated: 20, tag: "7EF1AB0400000100"),
        spool(6, "PLA", "Matte", color: "Ivory White", left: 0, updated: 18 * day, archived: "2026-10-18T08:00:00"),
    ]
}

private let catalog = [CatalogEntry(id: 1, name: "Bambu Lab - Reusable spool + refill", weight: 242)]

@MainActor
private func makeModel(
    _ inventory: FakeInventory? = FakeInventory(spools: inventorySpools()), settings: Settings = testSettings,
    feed: Bool = false, requiresHTTPS: Bool = false
) -> (SpoolsViewModel, Session) {
    inventory?.catalogEntries = catalog
    let session = Session(settings: settings, inventory: inventory, now: { testNow }, requiresHTTPS: requiresHTTPS)
    let feedModel = feed ? FeedViewModel(session: session, settings: settings) : nil
    let model = SpoolsViewModel(
        session: session, feed: feedModel, settings: settings, now: { testNow },
        locale: Locale(identifier: "en_GB"), timeZone: utc
    )
    return (model, session)
}

@MainActor
@Suite("SpoolsViewModel")
struct SpoolsViewModelTests {
    // MARK: Loading

    @Test func theFirstLoadShowsASpinnerThenTheActiveSpools() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, _) = makeModel(inventory)
        #expect(model.content == .loading)
        #expect(SpoolsViewModel.loadingTitle == "Loading spools\u{2026}")
        #expect(model.activeCount == nil)

        await model.refresh()

        #expect(model.content == .list)
        #expect(model.rows.map(\.id) == [12, 14, 21, 30, 27, 31, 33])
        #expect(model.activeCount == 7)
        #expect(model.staleNotice == nil)
        // One request, archived spools included; the scopes filter on the device.
        #expect(inventory.calls.filter { $0 == .listAll }.count == 1)
        #expect(!inventory.calls.contains(.list))
    }

    @Test func loadIfNeededLoadsOnce() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, _) = makeModel(inventory)
        await model.loadIfNeeded()
        await model.loadIfNeeded()
        #expect(inventory.calls.filter { $0 == .listAll }.count == 1)
        await model.refresh()
        #expect(inventory.calls.filter { $0 == .listAll }.count == 2)
    }

    @Test func theFooterCountsTheActiveSpools() async {
        let (model, _) = makeModel()
        #expect(model.footer == nil)
        await model.refresh()
        #expect(model.footer == "7 active spools. Pull down to refresh.")
        let (one, _) = makeModel(FakeInventory(spools: [spool(1, "PLA", left: 500)]))
        await one.refresh()
        #expect(one.footer == "1 active spool. Pull down to refresh.")
    }

    // MARK: Scopes, search, material, sort

    @Test func theScopesSplitActiveAndArchived() async {
        let (model, _) = makeModel()
        await model.refresh()
        #expect(SpoolsViewModel.Scope.allCases.map(\.title) == ["Active", "Archived", "All"])
        model.scope = .archived
        #expect(model.rows.map(\.id) == [6])
        model.scope = .all
        #expect(model.rows.count == 8)
    }

    @Test func searchUsesTheLinkPickersFilter() async {
        let (model, _) = makeModel()
        await model.refresh()
        #expect(SpoolsViewModel.searchPrompt == "Material, color, brand or note")
        model.query = "pla bambu"
        #expect(Set(model.rows.map(\.id)) == [12, 21])
        model.query = "DRAWER"
        #expect(model.rows.map(\.id) == [27])
        model.query = "copper esun"
        #expect(model.rows.map(\.id) == [30])
    }

    @Test func theMaterialFilterListsWhatTheInventoryHas() async {
        let (model, _) = makeModel()
        await model.refresh()
        #expect(model.materials == ["ASA", "PETG", "PLA", "TPU"])
        model.material = "PETG"
        #expect(model.rows.map(\.id) == [14, 27])
        #expect(model.isFiltering)
        model.material = nil
        #expect(!model.isFiltering)
        #expect(SpoolsViewModel.allMaterialsTitle == "All materials")
    }

    @Test func eachSortOrder() async {
        let (model, _) = makeModel()
        await model.refresh()
        #expect(SpoolsViewModel.Sort.allCases.map(\.title) == ["Recently updated", "Least left", "Material", "Color"])
        #expect(model.sort == .recentlyUpdated)
        // Newest first; a spool without updated_at last.
        #expect(model.rows.map(\.id) == [12, 14, 21, 30, 27, 31, 33])
        model.sort = .leastLeft
        #expect(model.rows.map(\.id) == [12, 21, 31, 30, 14, 27, 33])
        model.sort = .material
        #expect(model.rows.map(\.title) == ["ASA", "PETG", "PETG HF", "PLA Basic", "PLA Matte", "PLA Silk", "TPU 95A"])
        model.sort = .colour
        #expect(model.rows.compactMap(\.subtitle).map { $0.components(separatedBy: " \u{00B7} ")[0] }
            == ["Black", "Charcoal", "Copper", "Pumpkin Orange", "Red", "Transparent Blue", "White"])
    }

    @Test func spoolsWithoutAColourNameSortLast() async {
        let (model, _) = makeModel(FakeInventory(spools: [
            spool(1, "PLA", color: nil, left: 100), spool(2, "PLA", color: "Red", left: 100),
        ]))
        await model.refresh()
        model.sort = .colour
        #expect(model.rows.map(\.id) == [2, 1])
    }

    // MARK: Rows

    @Test func aRowReadsTitleColourBrandWhatIsLeftAndWhen() async throws {
        let (model, _) = makeModel()
        await model.refresh()
        let charcoal = try #require(model.rows.first { $0.id == 21 })
        #expect(charcoal.title == "PLA Matte")
        #expect(charcoal.subtitle == "Charcoal \u{00B7} Bambu Lab")
        #expect(charcoal.detail == "410 g left of 1,000 \u{00B7} updated 3 d ago")
        // What a narrow row keeps when the whole line does not fit.
        #expect(charcoal.left == "410 g left of 1,000")
        #expect(charcoal.hasTag)
        #expect(!charcoal.isLow)
        #expect(!charcoal.isArchived)
        #expect(charcoal.swatch != nil)
        #expect(
            charcoal.accessibilityLabel
                == "PLA Matte, Charcoal, Bambu Lab, 410 grams left of 1,000, tag linked, updated 3 days ago."
        )
        let white = try #require(model.rows.first { $0.id == 33 })
        #expect(white.detail == "990 g left of 1,000")
        #expect(white.hasTag)
    }

    @Test func lowAndArchivedAreWords() async throws {
        let (model, _) = makeModel()
        await model.refresh()
        let pumpkin = try #require(model.rows.first { $0.id == 12 })
        #expect(pumpkin.isLow)
        #expect(pumpkin.detail == "15 g left of 1,000 \u{00B7} updated just now")
        #expect(pumpkin.accessibilityLabel.contains("15 grams left of 1,000, low, tag linked"))
        #expect(SpoolsViewModel.lowWord == "Low")
        #expect(SpoolsViewModel.archivedWord == "Archived")
        model.scope = .archived
        let ivory = try #require(model.rows.first)
        #expect(ivory.isArchived)
        // An archived spool is empty, not low.
        #expect(!ivory.isLow)
        #expect(ivory.accessibilityLabel == "PLA Matte, Ivory White, Bambu Lab, 0 grams left of 1,000, archived, updated 18 days ago.")
    }

    @Test func lowIsUnderFifteenPercentOfTheLabel() {
        #expect(SpoolsViewModel.isLow(spool(1, "PLA", left: 149)))
        #expect(!SpoolsViewModel.isLow(spool(1, "PLA", left: 150)))
        #expect(SpoolsViewModel.isLow(spool(1, "TPU", label: 500, left: 74)))
        #expect(!SpoolsViewModel.isLow(spool(1, "PLA", label: 0, left: 0)))
    }

    @Test func updatedAgoInWholeUnits() {
        let texts = [0, 59, 5 * 60, 3 * 3600 + 59, 3 * day, 29 * day, 31 * day, 400 * day, -600].map {
            SpoolsViewModel.ago(testNow.addingTimeInterval(-$0), now: testNow)
        }
        #expect(texts == ["just now", "just now", "5 min ago", "3 h ago", "3 d ago", "29 d ago", "1 mo ago", "1 y ago", "just now"])
        let spoken = [60, 2 * 3600, day, 60 * day, 800 * day].map {
            SpoolsViewModel.ago(testNow.addingTimeInterval(-$0), now: testNow, spelledOut: true)
        }
        #expect(spoken == ["1 minute ago", "2 hours ago", "1 day ago", "2 months ago", "2 years ago"])
    }

    // MARK: States

    @Test func anEmptyInventorySaysSo() async throws {
        let (model, _) = makeModel(FakeInventory(spools: []))
        await model.refresh()
        #expect(model.content == .list)
        let empty = try #require(model.emptyResult)
        #expect(empty.title == "No spools in Bambuddy")
        #expect(empty.message == "Spools added in Bambuddy, or with New in the feed, show here.")
        #expect(empty.systemImage == "shippingbox")
        #expect(empty.action == nil)
    }

    @Test func noSearchResultsSaySo() async throws {
        let (model, _) = makeModel()
        await model.refresh()
        #expect(model.emptyResult == nil)
        model.query = "  nylon "
        let empty = try #require(model.emptyResult)
        #expect(empty.title == "No spools match \u{201C}nylon\u{201D}")
        #expect(empty.message == "Search looks at material, color, brand and note.")
        #expect(empty.systemImage == "magnifyingglass")
    }

    @Test func anEmptyMaterialOrScopeSaysWhichAndOffersAllMaterials() async throws {
        let (model, _) = makeModel()
        await model.refresh()
        model.scope = .archived
        model.material = "TPU"
        let material = try #require(model.emptyResult)
        #expect(material.title == "No TPU spools")
        #expect(material.message == "Choose All materials to see every spool.")
        #expect(material.action == .showAllMaterials)
        await model.perform(.showAllMaterials)
        #expect(model.material == nil)
        let (active, _) = makeModel(FakeInventory(spools: [spool(1, "PLA", left: 0, archived: "2026-10-18T08:00:00")]))
        await active.refresh()
        #expect(active.emptyResult?.title == "No active spools")
        #expect(active.emptyResult?.message == "Bambuddy has spools in the other scope.")
    }

    @Test func unreachableWithoutAListOffersRetry() async throws {
        let inventory = FakeInventory(spools: inventorySpools())
        inventory.listError = .network("no answer within 5 s")
        let (model, _) = makeModel(inventory)
        await model.refresh()
        guard case .unavailable(let state) = model.content else { Issue.record("\(model.content)"); return }
        #expect(state.title == "Can't reach Bambuddy")
        #expect(state.message == "Check that Bambuddy is running and on the same network.")
        #expect(state.systemImage == "wifi.exclamationmark")
        #expect(state.action == .retry)
        #expect(state.isProblem)
        inventory.listError = nil
        await model.perform(.retry)
        #expect(model.content == .list)
    }

    @Test func unreachableWithAListKeepsItAndSaysWhenItIsFrom() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, _) = makeModel(inventory)
        await model.refresh()
        inventory.listError = .network("no answer within 5 s")
        await model.refresh()
        #expect(model.content == .list)
        #expect(model.rows.count == 7)
        #expect(model.staleNotice == "Couldn't refresh \u{00B7} showing 10:42")
        inventory.listError = nil
        await model.refresh()
        #expect(model.staleNotice == nil)
    }

    @Test func noServerAsksToConnectBambuddy() async throws {
        var settings = testSettings
        settings.baseURL = ""
        let (model, _) = makeModel(nil, settings: settings)
        await model.refresh()
        guard case .unavailable(let state) = model.content else { Issue.record("\(model.content)"); return }
        #expect(state.title == "Connect Bambuddy")
        #expect(state.message == "Scan the API-key QR code in Bambuddy, or type its address.")
        #expect(state.systemImage == "server.rack")
        #expect(state.action == .openSettings)
        #expect(SpoolsViewModel.Action.openSettings.title == "Open Settings")
        #expect(SpoolsViewModel.Action.retry.title == "Retry")
    }

    @Test func aKeyWithoutInventoryReadSaysSo() async throws {
        let inventory = FakeInventory(spools: inventorySpools())
        inventory.listError = .permissionMissing("inventory:read")
        let (model, _) = makeModel(inventory)
        await model.refresh()
        guard case .unavailable(let state) = model.content else { Issue.record("\(model.content)"); return }
        #expect(state.title == "Can't read the inventory")
        #expect(state.message == "The API key needs the inventory:read permission. Add it to the key in Bambuddy.")
        #expect(state.systemImage == "lock.trianglebadge.exclamationmark")
        #expect(state.action == .openSettings)
    }

    @Test func aRejectedKeySaysSo() async throws {
        let inventory = FakeInventory(spools: inventorySpools())
        inventory.spoolmanError = .unauthorized
        let (model, _) = makeModel(inventory)
        await model.refresh()
        guard case .unavailable(let state) = model.content else { Issue.record("\(model.content)"); return }
        #expect(state.title == "Bambuddy rejected the API key")
        #expect(state.message == "Check the key in Settings, or scan the QR code of a new one.")
        #expect(state.action == .openSettings)
    }

    @Test func spoolmanModeBlocksAndRetryChecksAgain() async throws {
        let inventory = FakeInventory(spools: inventorySpools())
        inventory.spoolman = true
        let (model, _) = makeModel(inventory)
        await model.refresh()
        guard case .unavailable(let state) = model.content else { Issue.record("\(model.content)"); return }
        #expect(state == .spoolmanMode)
        #expect(state.title == "Bambuddy is in Spoolman mode")
        #expect(state.systemImage == "nosign")
        #expect(state.action == .retry)
        #expect(!inventory.calls.contains(.listAll))
        inventory.spoolman = false
        // A refusal sticks until Bambuddy is checked again; Retry does that.
        await model.refresh()
        #expect(model.content == .unavailable(.spoolmanMode))
        await model.perform(.retry)
        #expect(model.content == .list)
    }

    @Test func aProblemStateReplacesACachedList() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, _) = makeModel(inventory)
        await model.refresh()
        inventory.listError = .permissionMissing("inventory:read")
        await model.refresh()
        #expect(model.content == .unavailable(.noPermission))
        #expect(model.activeCount == nil)
    }

    @Test func anHTTPAddressAndAnUntrustedCertificateHaveTheirOwnStates() async {
        let (https, _) = makeModel(nil, settings: testSettings, requiresHTTPS: true)
        await https.refresh()
        #expect(https.content == .unavailable(.needsHTTPS))
        #expect(SpoolsViewModel.Unavailable.needsHTTPS.title == "Bambuddy needs HTTPS")
        #expect(SpoolsViewModel.Unavailable.needsHTTPS.action == .openSettings)

        let inventory = FakeInventory(spools: inventorySpools())
        inventory.spoolmanError = .untrustedCertificate
        let (certificate, _) = makeModel(inventory)
        await certificate.refresh()
        #expect(certificate.content == .unavailable(.untrustedCertificate))
        #expect(SpoolsViewModel.Unavailable.untrustedCertificate.action == .retry)
    }

    @Test func aListFromOtherSettingsIsNeverShown() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, session) = makeModel(inventory)
        await model.refresh()
        let other = FakeInventory(spools: [])
        other.listError = .network("no answer within 5 s")
        await session.reconfigure(settings: testSettings, inventory: other)
        await model.refresh()
        #expect(model.content == .unavailable(.unreachable))
        #expect(model.rows.isEmpty)
        #expect(model.activeCount == nil)
    }

    @Test func aServerChangeDropsTheListAndLoadsAgain() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, session) = makeModel(inventory)
        await model.refresh()
        model.selection = 21
        let other = FakeInventory(spools: [spool(1, "PLA", left: 500)])
        await session.reconfigure(settings: testSettings, inventory: other)
        await model.serverChanged()
        #expect(model.selection == nil)
        #expect(model.rows.map(\.id) == [1])
        #expect(other.calls.contains(.listAll))
    }

    @Test func aLoadFromOldSettingsFinishingAfterTheChangeIsDropped() async {
        let gate = ListGate()
        let old = FakeInventory(spools: inventorySpools())
        old.onList = { await gate.pass() }
        let (model, session) = makeModel(old)
        let loading = Task { await model.refresh() }
        await gate.untilHeld()
        let other = FakeInventory(spools: [spool(1, "PLA", left: 500)])
        await session.reconfigure(settings: testSettings, inventory: other)
        _ = model.forgetList()
        #expect(!model.isLoading)
        await gate.open()
        await loading.value
        #expect(model.rows.isEmpty)
        #expect(model.content == .loading)
        #expect(model.detail(for: 21) == nil)
        await model.refresh()
        #expect(model.rows.map(\.id) == [1])
    }

    @Test func aListFromOtherSettingsIsDroppedEvenWithoutAForget() async {
        let gate = ListGate()
        let old = FakeInventory(spools: inventorySpools())
        old.onList = { await gate.pass() }
        let (model, session) = makeModel(old)
        let loading = Task { await model.refresh() }
        await gate.untilHeld()
        await session.reconfigure(settings: testSettings, inventory: FakeInventory(spools: []))
        await gate.open()
        await loading.value
        #expect(model.rows.isEmpty)
        #expect(model.activeCount == nil)
        #expect(!model.isLoading)
    }

    @Test func aServerChangeBeforeAnyLoadLoadsNothing() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, _) = makeModel(inventory)
        await model.serverChanged()
        #expect(!inventory.calls.contains(.listAll))
        #expect(model.content == .loading)        // The sidebar's first load still happens.
        await model.loadIfNeeded()
        #expect(inventory.calls.filter { $0 == .listAll }.count == 1)
    }

    // MARK: Refresh after a write

    @Test func aSaveInTheFeedRefreshesTheList() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await model.refresh()
        #expect(model.rows.first?.detail.hasPrefix("484 g left") == true)

        var scan = try fixtureScan()
        scan.scanId = "s-1"
        _ = await session.handleScan(scan)
        let row = try #require(await session.rows.first)
        try await session.saveWeight(row: row.id, grams: 400, mode: .net)

        try await waitUntil { model.rows.first?.detail.hasPrefix("400 g left") == true }
        // The scan's lookup changed nothing in Bambuddy: one load for the save only.
        #expect(inventory.calls.filter { $0 == .listAll }.count == 2)
    }

    @Test func noRefreshBeforeTheFirstLoad() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        var scan = try fixtureScan()
        scan.scanId = "s-1"
        _ = await session.handleScan(scan)
        let row = try #require(await session.rows.first)
        try await session.saveWeight(row: row.id, grams: 400, mode: .net)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!inventory.calls.contains(.listAll))
    }

    // MARK: Detail

    @Test func theDetailListsWhatBambuddyKeeps() async throws {
        let (model, _) = makeModel()
        await model.refresh()
        let detail = try #require(model.detail(for: 21))
        #expect(detail.title == "PLA Matte")
        #expect(detail.subtitle == "Charcoal \u{00B7} Bambu Lab")
        #expect(detail.gaugeText == "410 g left of 1,000 g")
        #expect(detail.percentText == "41%")
        #expect(detail.fraction == 0.41)
        #expect(!detail.isLow)
        #expect(detail.facts == [
            .init("Material", "PLA"), .init("Subtype", "Matte"), .init("Brand", "Bambu Lab"),
            .init("Label weight", "1,000 g"), .init("Empty spool", "Bambu Lab - Reusable spool + refill \u{00B7} 242 g"),
            .init("Last scale weight", "652 g"), .init("Tag", "A1C3770E00000100", monospaced: true),
            .init("Spool #", "21"),
        ])
        #expect(detail.today == nil)
        #expect(detail.bambuddyURL == URL(string: "http://bambuddy.test:8000/inventory?spool=21"))
        #expect(SpoolsViewModel.Detail.footer == "Read-only. Edit spools in Bambuddy.")
        #expect(SpoolsViewModel.Detail.openTitle == "Open in Bambuddy")
    }

    @Test func theDetailOfAnUntaggedArchivedSpool() async throws {
        let (model, _) = makeModel()
        await model.refresh()
        let detail = try #require(model.detail(for: 6))
        #expect(detail.facts.map(\.label) == [
            "Material", "Subtype", "Brand", "Label weight", "Empty spool", "Last scale weight", "Tag", "Spool #",
            "Archived on",
        ])
        #expect(detail.facts.first { $0.label == "Empty spool" }?.value == "242 g")
        #expect(detail.facts.first { $0.label == "Last scale weight" }?.value == "Never weighed")
        #expect(detail.facts.first { $0.label == "Tag" } == .init("Tag", "No tag"))
        #expect(detail.facts.last?.value == "18 Oct 2026")
        #expect(detail.percentText == "0%")
        let copper = try #require(model.detail(for: 30))
        #expect(copper.facts.contains(.init("Note", "opened in September")))
    }

    @Test func theDetailShowsTodaysFeedLine() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory, feed: true)
        var scan = try fixtureScan()
        scan.scanId = "s-1"
        _ = await session.handleScan(scan)
        let row = try #require(await session.rows.first)
        try await session.saveWeight(row: row.id, grams: 400, mode: .net)
        model.feed?.apply(await session.snapshot)
        await model.refresh()
        let today = try #require(model.detail(for: 42)?.today)
        #expect(today.text == "Saved 400 g left \u{00B7} by Mac")
        #expect(today.symbol == .symbol("checkmark.circle.fill"))
        #expect(today.tint == .green)
        #expect(SpoolsViewModel.Detail.todayTitle == "Today")
    }

    @Test func aSpoolGoneFromBambuddyDropsTheSelection() async {
        let inventory = FakeInventory(spools: inventorySpools())
        let (model, _) = makeModel(inventory)
        await model.refresh()
        model.selection = 30
        #expect(model.selectedDetail?.title == "PLA Silk")
        inventory.removeQuietly(30)
        await model.refresh()
        #expect(model.selection == nil)
        #expect(model.selectedDetail == nil)
    }

    @Test func theBambuddyLinkKeepsAPathPrefixAndDropsCredentials() {
        #expect(SpoolsViewModel.bambuddyURL(base: "https://bambuddy.example.com/", spoolId: 7)
            == URL(string: "https://bambuddy.example.com/inventory?spool=7"))
        #expect(SpoolsViewModel.bambuddyURL(base: " https://example.com/bambuddy// ", spoolId: 7)
            == URL(string: "https://example.com/bambuddy/inventory?spool=7"))
        #expect(SpoolsViewModel.bambuddyURL(base: "https://me:secret@example.com", spoolId: 7)
            == URL(string: "https://example.com/inventory?spool=7"))
        #expect(SpoolsViewModel.bambuddyURL(base: "", spoolId: 7) == nil)
        #expect(SpoolsViewModel.bambuddyURL(base: "bambuddy.local", spoolId: 7) == nil)
    }
}

/// Holds `listSpools` until the test opens it.
private actor ListGate {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            held.append(continuation)
            for watcher in watchers { watcher.resume() }
            watchers.removeAll()
        }
    }

    func untilHeld() async {
        guard held.isEmpty else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held.removeAll()
    }
}

/// Polls `condition` on the main actor until it holds, for at most a second.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never held")
}
