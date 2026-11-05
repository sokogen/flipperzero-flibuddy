import Foundation
import Testing
@testable import FliBuddyCore

private func scan(_ scanId: String, _ name: String = "scan_mfc", autosave: Bool = false) throws -> Scan {
    var scan = try fixtureScan(name)
    scan.scanId = scanId
    scan.autosave = autosave
    return scan
}

private func row(
    status: FeedRow.Status, spool: Spool? = nil, request: FeedRow.HostRequest? = nil, _ name: String = "scan_mfc"
) throws -> FeedRow {
    var row = FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: status)
    row.request = request
    return row
}

/// A spool created for the tag (New, or Auto-save new on), in `status`.
private func addedRow(_ status: FeedRow.Status = .created) throws -> FeedRow {
    var added = try row(status: status, spool: knownSpool())
    added.createdSpoolId = added.spool?.id
    return added
}

/// A spool on the NTAG fixture, so that the Bambu fixture next to it is not in Bambuddy.
private func ntagSpool() throws -> Spool {
    let tag = TagParser.parse(try fixtureScan("scan_ntag").tag)
    return Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400, tagUid: tag.bambuddyTagUid)
}

@MainActor
private func makeModel(_ inventory: FakeInventory = FakeInventory()) -> (FeedViewModel, Session) {
    let session = Session(settings: testSettings, inventory: inventory)
    return (FeedViewModel(session: session, settings: testSettings), session)
}

/// The design's new-spool flow: a tag no spool carries offers New and Link
/// to existing…; New adds the spool at its label weight ("Added to
/// Bambuddy"), and the added row reopens for a weight like a saved one.
@Suite("FeedItem: a tag not in Bambuddy")
struct NewSpoolItemTests {
    @Test func anUnknownBambuTagIsNotInBambuddyAndDoesNotWait() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true)), coreWeight: 250)
        #expect(item.statusText == "Not in Bambuddy")
        #expect(item.statusSymbol == .symbol("questionmark.circle"))
        #expect(item.statusTint == .secondary)
        #expect(!item.isEntry)
        #expect(!item.isWaiting)
        #expect(!item.isReopenable)
        #expect(item.rowActions == [.new, .link])
        #expect(item.prominentRowAction == .new)
        #expect(item.accessibilityHeader.hasSuffix("Not in Bambuddy"))
    }

    @Test func aFlipperRequestKeepsItsActionProminent() throws {
        let create = FeedItem(try row(status: .unknown(prefill: true), request: .create))
        #expect(create.statusText == "Flipper asks to create it here")
        #expect(create.rowActions == [.new, .link])
        #expect(create.prominentRowAction == .new)
        #expect(!create.isEntry)

        let link = FeedItem(try row(status: .unknown(prefill: true), request: .link))
        #expect(link.statusText == "Flipper asks to link it here")
        #expect(link.rowActions == [.link, .new])
        #expect(link.prominentRowAction == .link)
        #expect(!link.isEntry)
    }

    /// A failed create on scan or a failed New: the error, and the same
    /// actions for the retry.
    @Test func anErrorKeepsNewAndLink() throws {
        let item = FeedItem(try row(status: .error("timed out")))
        #expect(item.statusText == "Error: timed out")
        #expect(!item.isEntry)
        #expect(item.rowActions == [.new, .link])
        #expect(item.prominentRowAction == .new)
    }

    /// The Flipper weighs a tag not in Bambuddy (Add and weigh): Saving…,
    /// no field and no actions.
    @Test func savingFromTheFlipperOffersNothing() throws {
        let item = FeedItem(try row(status: .saving))
        #expect(item.statusText == "Saving\u{2026}")
        #expect(!item.isEntry)
        #expect(item.rowActions.isEmpty)
        #expect(item.prominentRowAction == nil)
    }

    @Test func anAddedRowOffersNothingAndReopensForAWeight() throws {
        for added in [try addedRow(), try row(status: .created, spool: knownSpool())] {
            let item = FeedItem(added)
            #expect(item.statusText == "Added to Bambuddy")
            #expect(item.statusSymbol == .symbol("plus.circle.fill"))
            #expect(item.statusTint == .green)
            #expect(!item.isEntry)
            #expect(!item.isWaiting)
            #expect(item.isReopenable)
            #expect(item.rowActions.isEmpty)
            #expect(item.prominentRowAction == nil)
        }
    }

    /// The Flipper's Relink on host on the spool it just added: the row says
    /// so and offers Link, whose pick deletes the stand-in spool first.
    @Test func aFlipperRelinkOfAnAddedRowOffersLink() throws {
        var asked = try addedRow()
        asked.request = .link
        let item = FeedItem(asked)
        #expect(item.statusText == "Flipper asks to link it here")
        #expect(item.statusSymbol == .symbol("dot.radiowaves.left.and.right"))
        #expect(item.statusTint == .blue)
        #expect(item.rowActions == [.link])
        #expect(item.prominentRowAction == .link)
        #expect(!item.isEntry)
        #expect(!item.isWaiting)
        #expect(!item.isReopenable)
        #expect(item.accessibilityHeader.hasSuffix("Flipper asks to link it here"))

        // reopened, then asked: still Link, no entry
        asked.status = .awaitingWeight
        #expect(FeedItem(asked).rowActions == [.link])
        #expect(!FeedItem(asked).isEntry)

        // a failed Link keeps its error and Link for the retry
        asked.status = .error("boom")
        let failed = FeedItem(asked)
        #expect(failed.statusText == "Error: boom")
        #expect(failed.isError)
        #expect(failed.rowActions == [.link])
        #expect(!failed.isEntry)

        // while the Link runs: nothing to press
        asked.status = .saving
        #expect(FeedItem(asked).rowActions.isEmpty)
    }

    /// A spool this session did not add cannot be relinked from the host
    /// (Bambuddy refuses a tag an active spool carries): it keeps its entry.
    @Test func aRelinkRequestOnAnotherKnownSpoolKeepsTheEntry() throws {
        let item = FeedItem(try row(status: .awaitingWeight, spool: knownSpool(), request: .link))
        #expect(item.isEntry)
        #expect(item.rowActions.isEmpty)
        #expect(item.statusText == "Enter weight")
    }

    /// A weight on its way to an added spool, and a failed one: a known
    /// spool's entry.
    @Test func anAddedSpoolWeighedIsAKnownSpool() throws {
        for status: FeedRow.Status in [.saving, .error("boom")] {
            let item = FeedItem(try addedRow(status))
            #expect(item.isEntry, "\(status)")
            #expect(!item.isWaiting, "\(status)")
            #expect(item.rowActions.isEmpty, "\(status)")
        }
    }

    @Test func knownSpoolsKeepTheirEntry() throws {
        for status: FeedRow.Status in [.awaitingWeight, .saving, .updating, .error("boom")] {
            let item = FeedItem(try row(status: status, spool: knownSpool()))
            #expect(item.isEntry, "\(status)")
            #expect(item.rowActions.isEmpty, "\(status)")
        }
        #expect(FeedItem(try row(status: .awaitingWeight, spool: knownSpool())).isWaiting)
    }

    @Test func aTagWithoutMaterialOffersTheFormAndLink() throws {
        let blank = FeedItem(try row(status: .unknown(prefill: false), "scan_ntag"))
        #expect(blank.statusText == "Not in Bambuddy; tag has no material")
        #expect(blank.statusSymbol == .symbol("questionmark.circle"))
        #expect(!blank.isEntry)
        #expect(blank.rowActions == [.newForm, .link])
        #expect(blank.prominentRowAction == .newForm)
        let asked = FeedItem(try row(status: .unknown(prefill: false), request: .create, "scan_ntag"))
        #expect(asked.prominentRowAction == .newForm)
        let link = FeedItem(try row(status: .unknown(prefill: false), request: .link, "scan_ntag"))
        #expect(link.rowActions == [.link, .newForm])
        #expect(link.prominentRowAction == .link)
    }

    @Test func aDeletedSpoolOffersNewOrTheFormAndLink() throws {
        let deleted = FeedItem(try row(status: .deleted))
        #expect(deleted.rowActions == [.new, .link])
        #expect(deleted.prominentRowAction == .new)
        #expect(!deleted.isReopenable)
        #expect(FeedItem(try row(status: .deleted, "scan_ntag")).rowActions == [.newForm, .link])
    }

    @Test func lookingUpOffersNothing() throws {
        #expect(FeedItem(try row(status: .scanned)).rowActions.isEmpty)
    }

    @Test func theActionsReadTheSameOnEveryPlatform() {
        #expect(FeedItem.RowAction.new.title == "New")
        #expect(FeedItem.RowAction.newForm.title == "New\u{2026}")
        #expect(FeedItem.RowAction.link.title == "Link to existing\u{2026}")
    }
}

@MainActor
@Suite("FeedViewModel: New adds the spool at its label weight")
struct NewSpoolModelTests {
    /// A Bambu tag no spool carries, looked up with Auto-save new off.
    private func notInBambuddy(
        _ model: FeedViewModel, _ session: Session, _ scanId: String = "s-1"
    ) async throws -> FeedRow.ID {
        let id = await session.record(try scan(scanId))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)
        return id
    }

    /// A known NTAG spool, then a Bambu tag not in Bambuddy scanned after
    /// it (or before, `unknownFirst`).
    private func knownAndUnknown(
        _ model: FeedViewModel, _ session: Session, unknownFirst: Bool = false
    ) async throws -> (known: FeedRow.ID, unknown: FeedRow.ID) {
        var unknown: FeedRow.ID?
        if unknownFirst { unknown = await session.record(try scan("s-0")) }
        let known = await session.record(try scan("s-1", "scan_ntag"))
        if !unknownFirst { unknown = await session.record(try scan("s-2")) }
        let other = try #require(unknown)
        _ = await session.lookup(row: known)
        _ = await session.lookup(row: other)
        model.apply(await session.snapshot)
        return (known, other)
    }

    @Test func aTagNotInBambuddyNeverTakesFocusOrShowsAField() async throws {
        let (model, session) = makeModel()
        let id = try await notInBambuddy(model, session)

        #expect(model.item(id)?.statusText == "Not in Bambuddy")
        #expect(model.focusedRow == nil)
        #expect(model.focusedField == nil)
        #expect(!model.canSave(id))
    }

    @Test func aTagNotInBambuddyLeavesTheFocusOnAKnownSpool() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndUnknown(model, session)

        #expect(model.item(rows.unknown)?.statusText == "Not in Bambuddy")
        #expect(model.item(rows.known)?.statusText == "Enter weight")
        #expect(model.focusedRow == rows.known)
    }

    @Test func newAddsTheSpoolAtItsLabelWeightWithoutAWeight() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = try await notInBambuddy(model, session)

        #expect(await model.addNew(id))

        let tag = TagParser.parse(try fixtureScan().tag)
        let newSpool = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(inventory.creates == [.create(newSpool)])
        #expect(inventory.updates.isEmpty)
        let item = try #require(model.item(id))
        #expect(item.statusText == "Added to Bambuddy")
        #expect(item.remainingText == "1000 g left of 1000")
        #expect(!item.isEntry)
        #expect(item.rowActions.isEmpty)
        #expect(model.haptic?.kind == .success)
        #expect(model.focusedField == nil)
    }

    @Test func aFailedNewKeepsNewAndLinkForARetry() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = try await notInBambuddy(model, session)
        inventory.createError = .network("timed out")

        #expect(!(await model.addNew(id)))

        #expect(model.error(for: id) == "Bambuddy didn't answer")
        #expect(model.errorHint(for: id) == BambuddyError.network("timed out").localizedDescription)
        #expect(model.haptic?.kind == .error)
        let item = try #require(model.item(id))
        #expect(!item.isEntry)
        #expect(item.rowActions == [.new, .link])
        inventory.createError = nil
        #expect(await model.addNew(id))
        #expect(model.item(id)?.statusText == "Added to Bambuddy")
    }

    @Test func newIsRefusedWhereItIsNotOffered() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let known = await session.record(try scan("s-1"))
        _ = await session.lookup(row: known)
        let blank = await session.record(try scan("s-2", "scan_ntag"))
        _ = await session.lookup(row: blank)
        model.apply(await session.snapshot)

        #expect(!(await model.addNew(known)))
        // a tag without material needs the form
        #expect(!(await model.addNew(blank)))
        #expect(!(await model.addNew(UUID())))
        #expect(inventory.creates.isEmpty)
    }

    /// Tapping the added row opens it for a weight: Enter weight, focused,
    /// the label weight plus the core pre-filled.
    @Test func tappingAnAddedRowReopensItForAWeight() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = try await notInBambuddy(model, session)
        #expect(await model.addNew(id))

        await model.reopen(id)

        let item = try #require(model.item(id))
        #expect(item.statusText == "Enter weight")
        #expect(item.isEntry)
        #expect(item.isWaiting)
        #expect(model.focusedRow == id)
        #expect(model.focusedField == id)
        #expect(model.weightText(for: id) == "1250")
        model.setWeightText("1100", for: id)
        #expect(await model.save(id))
        #expect(inventory.creates.count == 1)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 1100)])
        #expect(model.item(id)?.statusText == "Saved 850 g left · by Mac")
    }

    @Test func anAddedOnScanRowWaitsForNothingUntilTapped() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)

        #expect(model.item(id)?.statusText == "Added to Bambuddy")
        #expect(model.item(id)?.isEntry == false)
        #expect(model.item(id)?.rowActions == [])
        #expect(model.focusedRow == nil)

        await model.reopen(id)
        #expect(model.focusedField == id)
        #expect(model.weightText(for: id) == "1250")
        model.setWeightText("1100", for: id)
        #expect(await model.save(id))
        #expect(inventory.creates.count == 1)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 1100)])
        #expect(model.item(id)?.isReopenable == true)
    }

    @Test func aFailedWeightOnAnAddedSpoolKeepsTheEntry() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        await model.reopen(id)
        model.setWeightText("1100", for: id)
        inventory.updateError = .network("timed out")

        #expect(!(await model.save(id)))

        let item = try #require(model.item(id))
        #expect(item.isError)
        #expect(item.isEntry)
        #expect(item.rowActions.isEmpty)
        #expect(model.weightText(for: id) == "1100")
    }

    /// Add on the Flipper, then Relink on host: the host offers Link, and the
    /// pick deletes the spool just added before it links the tag.
    @Test func aFlipperRelinkOfAnAddedSpoolDeletesItThenLinks() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        var relink = try fixtureIntent("intent_new")
        relink.id = "i-000009"
        relink.scanId = "s-1"
        relink.action = .linkOnHost
        #expect(await session.handleIntent(relink).ok)
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)

        let asked = try #require(model.item(id))
        #expect(asked.statusText == "Flipper asks to link it here")
        #expect(asked.rowActions == [.link])
        #expect(WatchRowScreen(asked, isCreating: false) == .unknown(hint: WatchRowScreen.linkHint, offersNew: false))

        await model.loadLinkCandidates()
        #expect(await model.link(id, toSpool: 7))

        let tag = TagParser.parse(try fixtureScan().tag)
        #expect(Array(inventory.calls.suffix(2)) == [.delete(spoolId: 100), .link(spoolId: 7, TagLink(tag: tag))])
        let item = try #require(model.items.first)
        #expect(item.spoolId == 7)
        #expect(item.statusText == "Enter weight")
        #expect(item.rowActions.isEmpty)
    }

    @Test func afterASaveFocusSkipsATagNotInBambuddy() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndUnknown(model, session, unknownFirst: true)
        #expect(model.focusedRow == rows.known)

        model.setWeightText("900", for: rows.known)
        #expect(await model.save(rows.known))

        // nothing else waits: the selection stays on the saved row
        #expect(model.focusedRow == rows.known)
        #expect(model.focusedField == nil)
    }

    @Test func afterASaveFocusSkipsAnAddedRow() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        _ = await session.handleScan(try scan("s-0", autosave: true))
        let known = await session.record(try scan("s-1", "scan_ntag"))
        _ = await session.lookup(row: known)
        model.apply(await session.snapshot)
        #expect(model.items.map(\.statusText) == ["Enter weight", "Added to Bambuddy"])
        #expect(model.focusedRow == known)

        model.setWeightText("900", for: known)
        #expect(await model.save(known))

        #expect(model.focusedRow == known)
    }

    @Test func theFlipperWeighingATagNotInBambuddyShowsSavingWithoutActions() async throws {
        let inventory = FakeInventory()
        inventory.updateDelay = .milliseconds(300)
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try fixtureScan())
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        #expect(model.item(id)?.statusText == "Not in Bambuddy")

        let pending = Task { await session.handleIntent(try weighIntent(grams: 1100, mode: .gross)) }
        #expect(await eventually { await session.rows.first?.status == .saving })
        model.apply(await session.snapshot)

        let item = try #require(model.item(id))
        #expect(item.statusText == "Saving\u{2026}")
        #expect(!item.isEntry)
        #expect(item.rowActions.isEmpty)
        _ = try await pending.value
    }
}
