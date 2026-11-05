import Foundation
import Testing
@testable import FliBuddyCore

@MainActor
@Suite("Demo fixtures")
struct DemoFixturesTests {
    // MARK: - Launch argument

    @Test func theLaunchArgumentTurnsTheDemoOn() {
        #expect(DemoFixtures.isRequested(["FliBuddy", "-FliBuddyDemo", "YES"]))
        #expect(DemoFixtures.isRequested(["FliBuddy", "-FliBuddyDemo", "1"]))
        #expect(!DemoFixtures.isRequested(["FliBuddy"]))
        #expect(!DemoFixtures.isRequested(["FliBuddy", "-FliBuddyDemo", "NO"]))
        #expect(!DemoFixtures.isRequested(["FliBuddy", "-FliBuddyDemo"]))
        #expect(!DemoFixtures.isRequested(["FliBuddy", "YES", "-FliBuddyDemo"]))
    }

    @Test func theDemoCanOpenOnAPane() {
        #expect(DemoFixtures.requestedPane(["FliBuddy", "-FliBuddyDemo", "YES", "-FliBuddyDemoPane", "spools"]) == "spools")
        #expect(DemoFixtures.requestedPane(["FliBuddy", "-FliBuddyDemo", "YES"]) == nil)
        #expect(DemoFixtures.requestedPane(["FliBuddy", "-FliBuddyDemo", "YES", "-FliBuddyDemoPane"]) == nil)
        // Only in the demo.
        #expect(DemoFixtures.requestedPane(["FliBuddy", "-FliBuddyDemoPane", "spools"]) == nil)
    }

    // MARK: - Tags

    @Test func aDemoBambuTagParsesBackToWhatItWasBuiltFrom() throws {
        let dump = DemoFixtures.bambuTag(
            uid: "91B4E7C2", materialId: "GFA00", variantId: "A00-G6", material: "PLA", detailedType: "PLA Basic",
            rgba: "00AE42FF", labelWeight: 1000
        )
        try dump.validate()
        let tag = TagParser.parse(dump)
        #expect(tag.kind == .bambu)
        #expect(tag.uid == "91B4E7C2")
        #expect(tag.material == "PLA")
        #expect(tag.detailedType == "PLA Basic")
        #expect(tag.rgba == "00AE42FF")
        #expect(tag.labelWeight == 1000)
        #expect(tag.diameter == 1.75)
        #expect(tag.bambuColor?.name == "Bambu Green")
        #expect(tag.bambuColor?.code == "10501")
    }

    @Test func aDemoNTAGIsATagWithoutMaterial() throws {
        let dump = DemoFixtures.ntagTag(uid: "04A2C93B1F5E80")
        try dump.validate()
        let tag = TagParser.parse(dump)
        #expect(tag.kind == .ntag)
        #expect(tag.uid == "04A2C93B1F5E80")
        #expect(!tag.hasPrefill)
    }

    // MARK: - Settings and inventory

    @Test func theSettingsAreAConfiguredHTTPSBambuddyAndAPairedFlipper() {
        let settings = DemoFixtures.settings
        #expect(settings.baseURL == "https://bambuddy.example.com")
        #expect(settings.apiKey == "demo-key")
        // Never a real-looking Bambuddy key.
        #expect(!settings.apiKey.hasPrefix("bb_"))
        #expect(settings.transport == .bluetooth)
        #expect(settings.peripheralName == "Atgizo")
        #expect(settings.peripheralId != nil)
        #expect(settings.coreWeight == 242)
        #expect(settings.catalogEntryId.map { id in DemoFixtures.catalog.contains { $0.id == id } } == true)
        #expect(Settings.isRefusedHTTP(settings.baseURL, requireHTTPS: true) == false)
        #expect(settings.isConfigured)
    }

    @Test func theInventoryHoldsADozenSpoolsAndTheCatalog() async throws {
        let inventory = DemoInventory()
        #expect(inventory.spools.count == 12)
        #expect(Set(inventory.spools.map(\.id)).count == 12)
        #expect(try await inventory.catalog() == DemoFixtures.catalog)
        #expect(DemoFixtures.catalog.count >= 3)
        #expect(try await inventory.spoolmanEnabled() == false)
        let green = try #require(try await inventory.findSpool(trayUuid: nil, uid: "91B4E7C200000100"))
        #expect(green.remaining == 590)
        #expect(green.labelWeight == 1000)
        #expect(green.suggestedGross == 832)
    }

    @Test func theDemoSpoolsWereUpdatedBeforeNineFortyOne() throws {
        for spool in DemoFixtures.spools {
            let updated = try #require(spool.updatedDate, "spool \(spool.id)")
            #expect(updated <= DemoFixtures.clockTime)
        }
        #expect(Set(DemoFixtures.spools.compactMap(\.updatedAt)).count == DemoFixtures.spools.count)
    }

    @Test func archivedSpoolsAreListedWhenAskedFor() async throws {
        let (_, inventory, _) = await playedSession()
        let active = try await inventory.listSpools()
        let all = try await inventory.listSpools(includeArchived: true)
        // The dozen and PLA Silk+, added on scan; Charcoal was marked empty.
        #expect(all.count == 13)
        #expect(active.count == 12)
        #expect(all.filter(\.isArchived).map(\.id) == [21])
    }

    @Test func aWriteStampsTheDemoClock() async throws {
        let (_, inventory, clock) = await playedSession()
        // The script weighed Pumpkin Orange at 09:30 and marked Charcoal empty at 09:20.
        let pumpkin = try #require(inventory.spools.first { $0.id == 12 })
        #expect(pumpkin.updatedDate == DemoFixtures.clockTime.addingTimeInterval(-11 * 60))
        _ = clock
    }

    // MARK: - The feed

    /// The session after the demo script, rows newest last.
    private func playedSession() async -> (Session, DemoInventory, DemoClock) {
        let clock = DemoClock()
        let inventory = DemoInventory(now: clock.now)
        let session = Session(settings: DemoFixtures.settings, inventory: inventory, now: clock.now)
        await DemoFixtures.play(on: session, clock: clock)
        return (session, inventory, clock)
    }

    private func row(_ rows: [FeedRow], uid: String) throws -> FeedRow {
        try #require(rows.first { $0.tag.uid == uid })
    }

    @Test func theScriptFillsTheFeedWithEachState() async throws {
        let (session, _, _) = await playedSession()
        let rows = await session.rows
        #expect(await session.bambuddy == .ready)
        #expect(rows.count == 7)

        // Newest: a known spool waiting for a weight, 590 g of 1000, suggested gross 832.
        let waiting = try #require(rows.last)
        #expect(waiting.tag.uid == "91B4E7C2")
        #expect(waiting.status == .awaitingWeight)
        #expect(waiting.spool?.remaining == 590)
        #expect(waiting.spool?.suggestedGross == 832)
        #expect(waiting.colorName == "Bambu Green")

        let saved = try row(rows, uid: "7EF1AB04")
        #expect(saved.status == .saved)
        #expect(saved.savedBy == .flipper)
        #expect(saved.spool?.remaining == 15)

        let notInBambuddy = try row(rows, uid: "3C9D20F1")
        #expect(notInBambuddy.status == .unknown(prefill: true))
        #expect(notInBambuddy.request == nil)
        #expect(notInBambuddy.tag.kind == .bambu)

        let added = try row(rows, uid: "8C33F05D")
        #expect(added.status == .created)
        #expect(added.createdSpoolId != nil)

        let asksToLink = try row(rows, uid: "D40E19A7")
        #expect(asksToLink.status == .unknown(prefill: true))
        #expect(asksToLink.request == .link)

        let blank = try row(rows, uid: "04A2C93B1F5E80")
        #expect(blank.tag.kind == .ntag)
        #expect(blank.status == .unknown(prefill: false))

        let archived = try row(rows, uid: "A1C3770E")
        #expect(archived.status == .markedEmpty)
        #expect(archived.savedBy == .flipper)
        #expect(archived.spool?.isArchived == true)
        // No row says "by host" (screenshots never show it).
        #expect(rows.allSatisfy { !FeedItem($0).statusText.contains("by host") })
        #expect(FeedItem(saved).statusText == "Saved 15 g left \u{00B7} by Flipper")
    }

    @Test func theScansHappenBeforeAFixedNineFortyOne() async throws {
        let (session, _, clock) = await playedSession()
        let rows = await session.rows
        let times = rows.map(\.scannedAt)
        #expect(times == times.sorted())
        #expect(Set(times).count == times.count)
        #expect(times.last == DemoFixtures.clockTime)
        #expect(clock.now() == DemoFixtures.clockTime)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: DemoFixtures.clockTime)
        #expect(parts.hour == 9)
        #expect(parts.minute == 41)
    }

    // MARK: - Actions

    @Test func savingAWeightChangesTheSpoolInMemory() async throws {
        let (session, inventory, _) = await playedSession()
        let waiting = try #require(await session.rows.last)

        try await session.saveWeight(row: waiting.id, grams: 800, mode: .gross)

        let spool = try #require(inventory.spools.first { $0.id == waiting.spool?.id })
        #expect(spool.lastScaleWeight == 800)
        #expect(spool.remaining == 558)
        #expect(await session.rows.last?.status == .saved)
        #expect(await session.rows.last?.savedBy == .host)
    }

    @Test func newAddsTheSpoolToTheInventory() async throws {
        let (session, inventory, _) = await playedSession()
        let rows = await session.rows
        let unknown = try row(rows, uid: "3C9D20F1")
        let before = inventory.spools.count
        let newSpool = try #require(
            NewSpool(tag: unknown.tag, coreWeight: 242, coreWeightCatalogId: DemoFixtures.settings.catalogEntryId)
        )

        let created = try await session.createSpool(row: unknown.id, newSpool)

        #expect(inventory.spools.count == before + 1)
        #expect(inventory.spools.contains { $0.id == created.id && $0.tagUid == "3C9D20F100000100" })
        #expect(try row(await session.rows, uid: "3C9D20F1").status == .created)
    }

    @Test func linkToExistingPutsTheTagOnTheChosenSpool() async throws {
        let (session, inventory, _) = await playedSession()
        let asksToLink = try row(await session.rows, uid: "D40E19A7")
        let listing = try await session.listSpools()
        // The archived spool is not offered.
        #expect(listing.spools.allSatisfy { !$0.isArchived })
        #expect(listing.spools.count >= 10)
        let target = try #require(listing.spools.first { $0.tagUid == nil })

        _ = try await session.link(row: asksToLink.id, toSpool: target.id, from: listing)

        let linked = try #require(inventory.spools.first { $0.id == target.id })
        #expect(linked.tagUid == "D40E19A700000100")
        let after = try row(await session.rows, uid: "D40E19A7")
        #expect(after.status == .awaitingWeight)
        #expect(after.request == nil)
    }

    @Test func linkingTheAddedSpoolElsewhereDeletesItFirst() async throws {
        let (session, inventory, _) = await playedSession()
        let added = try row(await session.rows, uid: "8C33F05D")
        let createdId = try #require(added.createdSpoolId)
        let listing = try await session.listSpools()
        let target = try #require(listing.spools.first { $0.tagUid == nil })

        _ = try await session.link(row: added.id, toSpool: target.id, from: listing)

        #expect(!inventory.spools.contains { $0.id == createdId })
        #expect(inventory.spools.first { $0.id == target.id }?.tagUid == "8C33F05D00000100")
    }

    // MARK: - The host

    @Test func theHostConnectsTheDemoFlipperAndFillsTheFeed() async throws {
        let demo = DemoFixtures.makeEnvironment()
        let host = demo.host
        let feed = Task { await host.feed.observe() }
        defer {
            feed.cancel()
            host.link.disconnect()
        }
        #expect(host.settings == DemoFixtures.settings)

        host.start()

        #expect(await eventually {
            if case .connected(let hello) = host.link.state { hello.fw == "1.5.1" } else { false }
        })
        #expect(host.link.connectedTransport == .bluetooth)
        #expect(await eventually { host.feed.items.count == 7 })
        #expect(await eventually { await host.session.bambuddy == .ready })
        #expect(host.sidebar.flipper.subline == "Atgizo \u{00B7} Bluetooth")
        #expect(await eventually { host.sidebar.bambuddy.subline == "Ready \u{00B7} bambuddy.example.com" })
    }

    @Test func aReconnectDoesNotPlayTheScriptAgain() async throws {
        let demo = DemoFixtures.makeEnvironment()
        let host = demo.host
        defer { host.link.disconnect() }
        host.start()
        #expect(await eventually { await host.session.rows.count == 7 })

        host.link.connect(host.settings.transportChoice)

        #expect(await eventually {
            if case .connected = host.link.state { true } else { false }
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await host.session.rows.count == 7)
    }

    @Test func scanForFlipperFindsTheDemoFlipperWithoutBluetooth() async throws {
        let host = DemoFixtures.makeHost()
        #expect(await host.link.bluetoothPowerState() == .poweredOn)
        var found: [DiscoveredPeripheral] = []
        for await peripheral in host.link.discoverFlippers() { found.append(peripheral) }
        #expect(found.map(\.name) == ["Atgizo"])
        #expect(found.first?.id == DemoFixtures.settings.peripheralId)
    }

    @Test func theSettingsScreenLoadsTheCatalog() async throws {
        let host = DemoFixtures.makeHost()
        let model = host.makeSettingsViewModel(appliesOnChange: true)

        await model.opened()

        #expect(model.catalog == DemoFixtures.catalog)
        #expect(model.catalogError == nil)
    }

    // MARK: - Nothing leaves memory

    private static let storedKeys = [
        "bambuddy.baseURL", "bambuddy.catalogEntryId", "bambuddy.coreWeight", "settings.version",
        "weight.defaultMode", "flipper.transport", "flipper.port", "flipper.peripheralId", "flipper.peripheralName",
    ]

    private func standardDefaults() -> [String: String] {
        var values: [String: String] = [:]
        for key in Self.storedKeys {
            values[key] = UserDefaults.standard.object(forKey: key).map { "\($0)" } ?? "-"
        }
        return values
    }

    @Test func settingsChangesStayInMemory() async throws {
        let before = standardDefaults()
        let demo = DemoFixtures.makeEnvironment()
        var changed = demo.host.settings
        changed.apiKey = "demo-key-2"
        changed.coreWeight = 250
        changed.baseURL = "https://other.example.com"

        try await demo.host.apply(changed)

        #expect(standardDefaults() == before)
        #expect(try demo.secrets.secret(for: SettingsStore.apiKeyAccount) == "demo-key-2")
        #expect(demo.defaults.object(forKey: "bambuddy.baseURL") as? String == "https://other.example.com")
        // Every configuration talks to the in-memory Bambuddy, never the network.
        #expect(try demo.makeInventory(changed) as? DemoInventory === demo.inventory)
        #expect(try demo.makeInventory(Settings()) as? DemoInventory === demo.inventory)
    }
}
