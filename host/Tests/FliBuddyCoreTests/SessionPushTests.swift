import Foundation
import Testing
@testable import FliBuddyCore

private func makeSession(_ inventory: FakeInventory) -> Session {
    Session(settings: testSettings, inventory: inventory)
}

/// The NTAG of `intent_create_on_host.json` with the material the host's form adds.
private func ntagForm(_ tag: ParsedTag) -> NewSpool {
    NewSpool(
        material: "PETG", colorName: "Jade White", labelWeight: 1000, coreWeight: 250, coreWeightCatalogId: 3,
        tagUid: tag.uid, tagType: tag.kind.bambuddyTagType
    )
}

@Suite("Session: lookups the host sends by itself")
struct SessionPushTests {
    @Test func creatingOnTheHostPushesAFreshLookupForTheScan() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let pushes = await Collector.draining(await session.pushes())
        _ = await session.handleIntent(try fixtureIntent("intent_create_on_host"))
        let row = try #require(await session.rows.first)

        let created = try await session.createSpool(row: row.id, ntagForm(row.tag))

        #expect(await eventually { await pushes.items.count == 1 })
        // a plain `found`: `created` is for spools made on scan (autosave)
        #expect(await pushes.items == [.lookup(LookupBuilder.found(scanId: row.scanId, spool: created))])
    }

    @Test func linkingOnTheHostPushesAFreshLookupForTheScan() async throws {
        let handAdded = Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 100)
        let inventory = FakeInventory(spools: [handAdded])
        let session = makeSession(inventory)
        let pushes = await Collector.draining(await session.pushes())
        _ = await session.handleIntent(try fixtureIntent("intent_link_on_host"))
        let row = try #require(await session.rows.first)

        let linked = try await session.link(row: row.id, toSpool: 7, from: try await session.listSpools())

        #expect(await eventually { await pushes.items.count == 1 })
        let lookup = try #require(await pushes.items.first)
        #expect(lookup == .lookup(LookupBuilder.found(scanId: "s-000013", spool: linked)))
    }

    @Test func aHostSaveThatCreatesTheSpoolPushesALookup() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let pushes = await Collector.draining(await session.pushes())
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)

        try await session.saveWeight(row: rowID, grams: 700, mode: .gross)

        #expect(await eventually { await pushes.items.count == 1 })
        let spool = try #require(await session.rows.first?.spool)
        #expect(await pushes.items == [.lookup(LookupBuilder.found(scanId: "s-000012", spool: spool))])
    }

    @Test func aHostSaveOnAKnownSpoolPushesNothing() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        let pushes = await Collector.draining(await session.pushes())
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)

        try await session.saveWeight(row: rowID, grams: 700, mode: .gross)
        // a create afterwards still pushes, so the stream is live
        let ntag = await session.record(try fixtureScan("scan_ntag"))
        let tag = try #require(await session.rows.last?.tag)
        _ = try await session.createSpool(row: ntag, ntagForm(tag))

        #expect(await eventually { await pushes.items.count == 1 })
        guard case .lookup(let lookup) = try #require(await pushes.items.first) else {
            Issue.record("expected a lookup")
            return
        }
        #expect(lookup.scanId == "s-000013")
    }

    @Test func aFailedHostActionPushesNothing() async throws {
        let inventory = FakeInventory()
        inventory.createError = .http(status: 422, message: "material: field required")
        let session = makeSession(inventory)
        let pushes = await Collector.draining(await session.pushes())
        _ = await session.handleIntent(try fixtureIntent("intent_create_on_host"))
        let row = try #require(await session.rows.first)

        await #expect(throws: BambuddyError.http(status: 422, message: "material: field required")) {
            try await session.createSpool(row: row.id, ntagForm(row.tag))
        }
        inventory.linkError = .tagAlreadyLinked(otherSpoolId: 42)
        await #expect(throws: BambuddyError.tagAlreadyLinked(otherSpoolId: 42)) {
            try await session.link(row: row.id, toSpool: 7, from: try await session.listSpools())
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await pushes.items.isEmpty)
    }

    @Test func thePushGoesToTheRowsLatestScan() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let pushes = await Collector.draining(await session.pushes())
        _ = await session.handleScan(try fixtureScan())
        var rescan = try fixtureScan()
        rescan.scanId = "s-000020"
        _ = await session.handleScan(rescan)
        let row = try #require(await session.rows.first)
        let form = try #require(NewSpool(tag: row.tag, coreWeight: 250, coreWeightCatalogId: 3))

        _ = try await session.createSpool(row: row.id, form)

        #expect(await eventually { await pushes.items.count == 1 })
        guard case .lookup(let lookup) = try #require(await pushes.items.first) else {
            Issue.record("expected a lookup")
            return
        }
        #expect(lookup.scanId == "s-000020")
        #expect(lookup.status == .found)
    }
}
