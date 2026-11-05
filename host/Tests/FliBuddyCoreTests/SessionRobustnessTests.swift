import Foundation
import Testing
@testable import FliBuddyCore

private func makeSession(_ inventory: FakeInventory) -> Session {
    Session(settings: testSettings, inventory: inventory)
}

/// `knownSpool()` under another id: the tag's spool made again elsewhere.
private func remadeSpool() -> Spool {
    var spool = knownSpool()
    spool.id = 43
    return spool
}

@Suite("Session: a spool deleted elsewhere, the feed cap")
struct SessionRobustnessTests {
    // MARK: A spool deleted elsewhere

    @Test func aWeighOfASpoolDeletedElsewhereLooksTheTagUpAgain() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.removeQuietly(42)
        inventory.addQuietly(remadeSpool())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(inventory.updates == [.update(spoolId: 42, gross: 734), .update(spoolId: 43, gross: 734)])
        let row = try #require(await session.rows.first)
        #expect(row.spool?.id == 43)
        #expect(row.status == .saved)
    }

    @Test func aWeighOfASpoolGoneEverywhereCreatesItFromTheTag() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.removeQuietly(42)

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(inventory.creates.count == 1)
        #expect(inventory.updates.last == .update(spoolId: 100, gross: 734))
        #expect(await session.rows.first?.spool?.id == 100)
    }

    @Test func aHostWeightForASpoolDeletedElsewhereLooksTheTagUpAgain() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)
        inventory.removeQuietly(42)
        inventory.addQuietly(remadeSpool())

        try await session.saveWeight(row: rowID, grams: 734, mode: .gross)

        #expect(inventory.updates.last == .update(spoolId: 43, gross: 734))
        #expect(await session.rows.first?.spool?.id == 43)
    }

    @Test func aHostWeightForASpoolGoneEverywhereWithoutMaterialClearsTheSpool() async throws {
        let spool = Spool(id: 42, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 0, tagUid: "04112233445566")
        let inventory = FakeInventory(spools: [spool])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan("scan_ntag"))
        let rowID = try #require(await session.rows.first?.id)
        #expect(await session.rows.first?.spool?.id == 42)
        inventory.removeQuietly(42)

        await #expect(throws: SessionError.spoolNotFound("04112233445566")) {
            try await session.saveWeight(row: rowID, grams: 734, mode: .gross)
        }

        #expect(await session.rows.first?.spool == nil)
        #expect(inventory.creates.isEmpty)
    }

    @Test func aWeighLooksTheTagUpAgainOnceOnly() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateError = .spoolNotFound(42)
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(!result.ok)
        #expect(inventory.updates.count == 2)
    }

    @Test func markAsNewOfASpoolDeletedElsewhereLooksTheTagUpAgain() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.removeQuietly(42)
        inventory.addQuietly(remadeSpool())

        let result = await session.handleIntent(try fixtureIntent("intent_full"))

        #expect(result.ok)
        #expect(inventory.writes == [.setUsed(spoolId: 42, grams: 0), .setUsed(spoolId: 43, grams: 0)])
        #expect(await session.rows.first?.spool?.id == 43)
    }

    @Test func markAsEmptyOfASpoolGoneEverywhereSaysNotFound() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.removeQuietly(42)

        let result = await session.handleIntent(try fixtureIntent("intent_empty"))

        #expect(!result.ok)
        #expect(result.lines == ["Not saved", "Spool not found"])
        let row = try #require(await session.rows.first)
        #expect(row.spool == nil)
        #expect(row.status == .unknown(prefill: true))
    }

    // MARK: The feed cap

    @Test func theFeedKeepsTheNewestRows() async throws {
        let session = makeSession(FakeInventory())
        var scan = try fixtureScan("scan_ntag")
        let count = Session.maxRows + 5
        for index in 0..<count {
            scan.scanId = "s-\(index)"
            scan.tag.uid = String(format: "04%012X", index)
            await session.record(scan)
        }

        let rows = await session.rows
        #expect(Session.maxRows == 200)
        #expect(rows.count == Session.maxRows)
        #expect(rows.first?.scanId == "s-5")
        #expect(rows.last?.scanId == "s-\(count - 1)")
    }

    @Test func anIntentForADroppedRowStartsANewOne() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        var scan = try fixtureScan("scan_ntag")
        for index in 0..<Session.maxRows {
            scan.scanId = "s-n\(index)"
            scan.tag.uid = String(format: "04%012X", index)
            await session.record(scan)
        }
        #expect(await !session.rows.contains { $0.scanId == "s-000012" })

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(await session.rows.count == Session.maxRows)
        #expect(await session.rows.last?.spool?.id == 42)
    }
}
