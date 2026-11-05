import Foundation
import Testing
@testable import FliBuddyCore

/// `knownSpool()` in Bambuddy's archive: marked empty, last weighed as the bare core.
private func archivedSpool() -> Spool {
    var spool = knownSpool(lastScaleWeight: 250, weightUsed: 1000)
    spool.archivedAt = "2026-10-26T12:00:00"
    return spool
}

private func makeSession(_ inventory: FakeInventory) -> Session {
    Session(settings: testSettings, inventory: inventory)
}

@Suite("Session: Mark as new, Mark as empty, Delete")
struct SessionMarkTests {
    // MARK: Mark as new

    @Test func markAsNewSetsWeightUsedToZero() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try fixtureIntent("intent_full"))

        #expect(result == (try fixtureResult("result_full")))
        #expect(inventory.writes == [.setUsed(spoolId: 42, grams: 0)])
        let row = try #require(await session.rows.first)
        #expect(row.status == .markedNew)
        #expect(row.savedBy == .flipper)
        #expect(row.spool?.remaining == 1000)
        #expect(FeedItem(row).statusText == "Marked as new · 1000 g left · by Flipper")
    }

    @Test func markAsNewRestoresAnArchivedSpoolFirst() async throws {
        let inventory = FakeInventory(spools: [archivedSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try fixtureIntent("intent_full"))

        #expect(result == (try fixtureResult("result_full")))
        #expect(inventory.writes == [.restore(spoolId: 42), .setUsed(spoolId: 42, grams: 0)])
        #expect(inventory.spools.first?.isArchived == false)
        #expect(await session.rows.first?.spool?.isArchived == false)
    }

    // MARK: Mark as empty

    @Test func markAsEmptyUsesTheLabelWeightThenArchives() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try fixtureIntent("intent_empty"))

        #expect(result == (try fixtureResult("result_empty")))
        #expect(inventory.writes == [.setUsed(spoolId: 42, grams: 1000), .archive(spoolId: 42)])
        #expect(inventory.spools.first?.isArchived == true)
        let row = try #require(await session.rows.first)
        #expect(row.status == .markedEmpty)
        #expect(row.spool?.isArchived == true)
        #expect(row.spool?.remaining == 0)
        #expect(FeedItem(row).statusText == "Marked as empty · archived · by Flipper")
    }

    @Test func markAsEmptyDoesNotArchiveAnArchivedSpoolAgain() async throws {
        let inventory = FakeInventory(spools: [archivedSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try fixtureIntent("intent_empty"))

        #expect(result.ok)
        #expect(inventory.writes == [.setUsed(spoolId: 42, grams: 1000)])
    }

    @Test func aFailedArchiveIsRetriedOnARepeatedId() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.archiveError = .network("timed out")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try fixtureIntent("intent_empty")

        let first = await session.handleIntent(intent)
        #expect(!first.ok)
        #expect(first.lines == ["Not saved"])
        #expect(first.spool == nil)
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))

        inventory.archiveError = nil
        let second = await session.handleIntent(intent)
        #expect(second == (try fixtureResult("result_empty")))
        #expect(inventory.writes.filter { $0 == .archive(spoolId: 42) }.count == 2)
    }

    // MARK: Delete

    @Test func deleteRemovesTheSpoolAndFreesTheTag() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try fixtureIntent("intent_delete"))

        #expect(result == (try fixtureResult("result_delete")))
        #expect(inventory.writes == [.delete(spoolId: 42)])
        #expect(inventory.spools.isEmpty)
        let row = try #require(await session.rows.first)
        #expect(row.status == .deleted)
        #expect(row.spool == nil)
        let item = FeedItem(row)
        #expect(item.statusText == "Deleted from Bambuddy · by Flipper")
        #expect(item.offersUnknownActions)
    }

    @Test func aSpoolDeletedElsewhereCountsAsDeleted() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.onDelete = { inventory.removeQuietly(42) }

        let result = await session.handleIntent(try fixtureIntent("intent_delete"))

        #expect(result.ok)
        #expect(await session.rows.first?.status == .deleted)
    }

    @Test func aFailedDeleteSaysNotDeletedAndIsRetried() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.deleteError = .http(status: 500, message: "boom")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try fixtureIntent("intent_delete")

        let first = await session.handleIntent(intent)
        #expect(!first.ok)
        #expect(first.lines == ["Not deleted"])
        #expect(await session.rows.first?.spool?.id == 42)

        inventory.deleteError = nil
        #expect(await session.handleIntent(intent).ok)
        #expect(inventory.spools.isEmpty)
    }

    // MARK: Shared rules

    @Test(arguments: ["intent_full", "intent_empty", "intent_delete"])
    func anActionOnATagWithoutASpoolFails(name: String) async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try fixtureIntent(name))

        #expect(!result.ok)
        #expect(result.lines == [name == "intent_delete" ? "Not deleted" : "Not saved", "Spool not found"])
        #expect(result.error == "no spool for tag 5A3C9E21")
        #expect(inventory.writes.isEmpty)
        #expect(await session.rows.first?.status == .unknown(prefill: true))
    }

    @Test(arguments: ["intent_full", "intent_empty", "intent_delete"])
    func aRepeatedIntentIsAnsweredWithoutCallingBambuddyAgain(name: String) async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try fixtureIntent(name)

        let first = await session.handleIntent(intent)
        let writes = inventory.writes
        let second = await session.handleIntent(intent)

        #expect(first.ok)
        #expect(second == first)
        #expect(inventory.writes == writes)
    }

    @Test func theRowShowsUpdatingWhileBambuddyWorks() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let seen = Recorded<FeedItem?>()
        inventory.onDelete = { await seen.append(session.rows.first.map { FeedItem($0) }) }

        _ = await session.handleIntent(try fixtureIntent("intent_delete"))

        let during = try #require(await seen.values.first ?? nil)
        #expect(during.statusText == "Updating\u{2026}")
        #expect(during.isSaving)
    }

    @Test func anIntentWithoutARowLooksTheSpoolUpByTag() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)

        let result = await session.handleIntent(try fixtureIntent("intent_full"))

        #expect(result.ok)
        #expect(inventory.writes == [.setUsed(spoolId: 42, grams: 0)])
    }

    @Test func aMarkedRowReopensForAWeight() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        _ = await session.handleScan(try fixtureScan())
        _ = await session.handleIntent(try fixtureIntent("intent_empty"))
        let row = try #require(await session.rows.first)
        #expect(FeedItem(row).isReopenable)

        await session.reopen(row: row.id)

        #expect(await session.rows.first?.status == .awaitingWeight)
    }

    /// Added to Bambuddy (here a create on scan) reopens like a saved row.
    @Test func anAddedRowReopensForAWeight() async throws {
        let session = makeSession(FakeInventory())
        var scan = try fixtureScan()
        scan.autosave = true
        _ = await session.handleScan(scan)
        let row = try #require(await session.rows.first)
        #expect(row.status == .created)

        await session.reopen(row: row.id)

        #expect(await session.rows.first?.status == .awaitingWeight)
    }

    // MARK: Archived spools

    @Test func anArchivedSpoolIsFoundAndSaysSo() async throws {
        let session = makeSession(FakeInventory(spools: [archivedSpool()]))

        let lookup = await session.handleScan(try fixtureScan())

        #expect(lookup == (try fixtureLookup("lookup_found_archived")))
        #expect(await session.rows.first?.status == .awaitingWeight)
    }

    @Test func aRescanAfterMarkAsEmptyFindsTheArchivedSpoolAndMovesTheRowUp() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        _ = await session.handleIntent(try fixtureIntent("intent_empty"))
        _ = await session.handleScan(try fixtureScan("scan_ntag"))

        var again = try fixtureScan()
        again.scanId = "s-000020"
        let lookup = await session.handleScan(again)

        #expect(lookup.status == .found)
        #expect(lookup.spool?.archived == true)
        #expect(lookup.lines[2] == "archived")
        #expect(inventory.creates.isEmpty)
        let rows = await session.rows
        #expect(rows.map(\.scanId) == ["s-000013", "s-000020"])
        #expect(rows.last?.status == .awaitingWeight)
    }

    @Test func aWeighOnAnArchivedSpoolRestoresItFirst() async throws {
        let inventory = FakeInventory(spools: [archivedSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(result.spool?.archived == false)
        #expect(inventory.writes == [.restore(spoolId: 42), .update(spoolId: 42, gross: 734)])
        #expect(await session.rows.first?.spool?.isArchived == false)
    }

    @Test func aHostSaveOnAnArchivedSpoolRestoresItFirst() async throws {
        let inventory = FakeInventory(spools: [archivedSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)

        try await session.saveWeight(row: rowID, grams: 500, mode: .net)

        #expect(inventory.writes == [.restore(spoolId: 42), .update(spoolId: 42, gross: 750)])
    }

    @Test func archivedSpoolsAreLeftOutOfTheLinkPicker() async throws {
        var other = knownSpool()
        other.id = 7
        other.tagUid = nil
        let session = makeSession(FakeInventory(spools: [archivedSpool(), other]))

        let listing = try await session.listSpools()

        #expect(listing.spools.map(\.id) == [7])
    }

    @Test func newSettingsRefuseAMarkWhoseWriteHadNotBegun() async throws {
        let old = FakeInventory(spools: [knownSpool()])
        let session = makeSession(old)
        _ = await session.handleScan(try fixtureScan())
        let other = FakeInventory(spools: [knownSpool()])
        // new settings leave the row's spool stale, so the intent looks it up
        // again; the settings change once more during that lookup
        await session.reconfigure(settings: testSettings, inventory: old)
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let result = await session.handleIntent(try fixtureIntent("intent_full"))

        #expect(result.ok)
        #expect(old.writes.isEmpty)
        #expect(other.writes == [.setUsed(spoolId: 42, grams: 0)])
    }
}
