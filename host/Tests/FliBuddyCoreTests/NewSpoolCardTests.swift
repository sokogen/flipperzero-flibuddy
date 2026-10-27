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

/// A spool created for the tag on scan (Auto-save new on), in `status`.
private func createdRow(_ status: FeedRow.Status = .created) throws -> FeedRow {
    var created = try row(status: status, spool: knownSpool())
    created.createdSpoolId = created.spool?.id
    return created
}

/// A spool on the NTAG fixture, so that the Bambu fixture next to it is a New spool.
private func ntagSpool() throws -> Spool {
    let tag = TagParser.parse(try fixtureScan("scan_ntag").tag)
    return Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400, tagUid: tag.bambuddyTagUid)
}

@MainActor
private func makeModel(_ inventory: FakeInventory = FakeInventory()) -> (FeedViewModel, Session) {
    let session = Session(settings: testSettings, inventory: inventory)
    return (FeedViewModel(session: session, settings: testSettings), session)
}

@Suite("FeedItem: the new spool card")
struct NewSpoolCardItemTests {
    @Test func anUnknownBambuTagIsANewSpoolThatDoesNotWait() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true)), coreWeight: 250)
        #expect(item.statusText == "New spool")
        #expect(item.statusSymbol == .symbol("plus.circle"))
        #expect(item.statusTint == .secondary)
        #expect(item.revealsEntry)
        #expect(!item.isEntry)
        #expect(!item.isWaiting)
        #expect(!item.savesNewSpool)
        #expect(item.rowActions == [.saveAsNew, .saveWithWeight, .link])
        #expect(item.prominentRowAction == .saveAsNew)
        #expect(item.accessibilityHeader.hasSuffix("New spool"))
    }

    @Test func aFlipperRequestKeepsItsActionProminent() throws {
        let create = FeedItem(try row(status: .unknown(prefill: true), request: .create))
        #expect(create.statusText == "Flipper asks to create it here")
        #expect(create.rowActions == [.saveAsNew, .saveWithWeight, .link])
        #expect(create.prominentRowAction == .saveAsNew)
        #expect(!create.isEntry)

        let link = FeedItem(try row(status: .unknown(prefill: true), request: .link))
        #expect(link.statusText == "Flipper asks to link it here")
        #expect(link.rowActions == [.link, .saveAsNew, .saveWithWeight])
        #expect(link.prominentRowAction == .link)
        #expect(!link.isEntry)
    }

    /// A failed create on scan or a failed Save as new: the error, and the
    /// same actions for the retry.
    @Test func anErrorKeepsTheNewSpoolActions() throws {
        let item = FeedItem(try row(status: .error("timed out")))
        #expect(item.statusText == "Error: timed out")
        #expect(item.revealsEntry)
        #expect(!item.isEntry)
        #expect(item.rowActions == [.saveAsNew, .saveWithWeight, .link])
    }

    @Test func revealedTheNewSpoolWaitsForAWeightWhoseSaveCreatesTheSpool() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true)), coreWeight: 250, entryRevealed: true)
        #expect(item.statusText == "New spool")
        #expect(item.isEntry)
        #expect(item.isWaiting)
        #expect(item.savesNewSpool)
        #expect(item.rowActions == [.link])
        #expect(item.prominentRowAction == nil)
        #expect(item.suggestion(mode: .gross) == 1250)
        // saving, then a failed save: the entry stays, no longer waiting
        for status: FeedRow.Status in [.saving, .error("boom")] {
            let after = FeedItem(try row(status: status), entryRevealed: true)
            #expect(after.isEntry, "\(status)")
            #expect(after.savesNewSpool, "\(status)")
            #expect(!after.isWaiting, "\(status)")
        }
    }

    /// The Flipper weighs a New spool: Saving…, no field and no actions.
    @Test func aNewSpoolSavingFromTheFlipperOffersNothing() throws {
        let item = FeedItem(try row(status: .saving))
        #expect(item.statusText == "Saving\u{2026}")
        #expect(!item.isEntry)
        #expect(item.rowActions.isEmpty)
        #expect(item.prominentRowAction == nil)
    }

    @Test func aCreatedRowDoesNotWaitAndOffersSetWeightAndLink() throws {
        let item = FeedItem(try createdRow())
        #expect(item.statusText == "Created in Bambuddy")
        #expect(item.revealsEntry)
        #expect(!item.isEntry)
        #expect(!item.isWaiting)
        #expect(item.offersLinkExisting)
        #expect(item.rowActions == [.setWeight, .link])
        #expect(item.prominentRowAction == .setWeight)

        let revealed = FeedItem(try createdRow(), entryRevealed: true)
        #expect(revealed.isEntry)
        #expect(revealed.isWaiting)
        #expect(!revealed.savesNewSpool)
        #expect(revealed.rowActions == [.link])
        #expect(revealed.prominentRowAction == nil)
    }

    /// A failed Set weight or Link keeps the card; revealed, the entry.
    @Test func aCreatedRowWithAnErrorStaysACard() throws {
        let failed = FeedItem(try createdRow(.error("boom")))
        #expect(failed.revealsEntry)
        #expect(!failed.isEntry)
        #expect(failed.rowActions == [.setWeight, .link])
        let revealed = FeedItem(try createdRow(.error("boom")), entryRevealed: true)
        #expect(revealed.isEntry)
        #expect(!revealed.isWaiting)
    }

    /// New settings forget which spool was created here: Link would no
    /// longer delete it, so only Set weight… is left.
    @Test func aCreatedRowUnderNewSettingsOffersOnlySetWeight() throws {
        let item = FeedItem(try row(status: .created, spool: knownSpool()))
        #expect(item.revealsEntry)
        #expect(!item.isEntry)
        #expect(!item.offersLinkExisting)
        #expect(item.rowActions == [.setWeight])
    }

    @Test func knownSpoolsKeepTheirEntry() throws {
        for status: FeedRow.Status in [.awaitingWeight, .saving, .updating, .error("boom")] {
            let item = FeedItem(try row(status: status, spool: knownSpool()))
            #expect(!item.revealsEntry, "\(status)")
            #expect(item.isEntry, "\(status)")
            #expect(item.rowActions.isEmpty, "\(status)")
        }
        #expect(FeedItem(try row(status: .awaitingWeight, spool: knownSpool())).isWaiting)
        // a reveal means nothing to a known spool
        let saved = FeedItem(try row(status: .saved, spool: knownSpool()), entryRevealed: true)
        #expect(!saved.isEntry)
    }

    @Test func aTagWithoutMaterialOffersTheFormAndLink() throws {
        let blank = FeedItem(try row(status: .unknown(prefill: false), "scan_ntag"))
        #expect(blank.statusText == "Not in Bambuddy; tag has no material")
        #expect(!blank.revealsEntry)
        #expect(!blank.isEntry)
        #expect(blank.rowActions == [.newForm, .link])
        #expect(blank.prominentRowAction == nil)
        let asked = FeedItem(try row(status: .unknown(prefill: false), request: .create, "scan_ntag"))
        #expect(asked.prominentRowAction == .newForm)
        let link = FeedItem(try row(status: .unknown(prefill: false), request: .link, "scan_ntag"))
        #expect(link.rowActions == [.link, .newForm])
        #expect(link.prominentRowAction == .link)
    }

    @Test func aDeletedSpoolOffersSaveAsNewOrTheFormAndLink() throws {
        #expect(FeedItem(try row(status: .deleted)).rowActions == [.saveAsNew, .link])
        #expect(FeedItem(try row(status: .deleted, "scan_ntag")).rowActions == [.newForm, .link])
        #expect(!FeedItem(try row(status: .deleted)).revealsEntry)
    }

    @Test func lookingUpOffersNothing() throws {
        let item = FeedItem(try row(status: .scanned))
        #expect(!item.revealsEntry)
        #expect(item.rowActions.isEmpty)
    }

    @Test func theActionsReadTheSameOnEveryPlatform() {
        #expect(FeedItem.RowAction.saveAsNew.title == "Save as new")
        #expect(FeedItem.RowAction.saveWithWeight.title == "Save with weight\u{2026}")
        #expect(FeedItem.RowAction.setWeight.title == "Set weight\u{2026}")
        #expect(FeedItem.RowAction.newForm.title == "New\u{2026}")
        #expect(FeedItem.RowAction.link.title == "Link to existing\u{2026}")
        #expect(FeedItem.RowAction.saveAsNew.watchTitle == "Save as new")
        #expect(FeedItem.RowAction.saveWithWeight.watchTitle == "With weight")
        #expect(FeedItem.RowAction.setWeight.watchTitle == "Set weight")
    }
}

@MainActor
@Suite("FeedViewModel: the new spool card")
struct NewSpoolCardModelTests {
    /// A Bambu tag no spool carries, looked up with Auto-save new off.
    private func newSpool(_ model: FeedViewModel, _ session: Session, _ scanId: String = "s-1") async throws -> FeedRow.ID {
        let id = await session.record(try scan(scanId))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)
        return id
    }

    /// A known NTAG spool, then a New spool scanned after it (or before, `newFirst`).
    private func knownAndNew(
        _ model: FeedViewModel, _ session: Session, newFirst: Bool = false
    ) async throws -> (known: FeedRow.ID, new: FeedRow.ID) {
        var unknown: FeedRow.ID?
        if newFirst { unknown = await session.record(try scan("s-0")) }
        let known = await session.record(try scan("s-1", "scan_ntag"))
        if !newFirst { unknown = await session.record(try scan("s-2")) }
        let new = try #require(unknown)
        _ = await session.lookup(row: known)
        _ = await session.lookup(row: new)
        model.apply(await session.snapshot)
        return (known, new)
    }

    @Test func aNewSpoolNeverTakesFocusOrShowsAField() async throws {
        let (model, session) = makeModel()
        let id = try await newSpool(model, session)

        #expect(model.item(id)?.statusText == "New spool")
        #expect(model.focusedRow == nil)
        #expect(model.focusedField == nil)
        #expect(!model.canSave(id))
    }

    @Test func aNewSpoolScanLeavesTheFocusOnAKnownSpool() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndNew(model, session)

        #expect(model.item(rows.new)?.statusText == "New spool")
        #expect(model.item(rows.known)?.statusText == "Enter weight")
        #expect(model.focusedRow == rows.known)
    }

    @Test func saveAsNewCreatesTheSpoolFullWithoutAWeight() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = try await newSpool(model, session)

        #expect(await model.saveAsNew(id))

        #expect(inventory.creates.count == 1)
        #expect(inventory.updates.isEmpty)
        let item = try #require(model.item(id))
        #expect(item.statusText == "Created in Bambuddy")
        #expect(!item.isEntry)
        #expect(item.rowActions == [.setWeight, .link])
        #expect(model.haptic?.kind == .success)
        #expect(model.focusedField == nil)
    }

    @Test func aFailedSaveAsNewKeepsTheCardForARetry() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = try await newSpool(model, session)
        inventory.createError = .network("timed out")

        #expect(!(await model.saveAsNew(id)))

        let message = BambuddyError.network("timed out").localizedDescription
        #expect(model.error(for: id) == message)
        #expect(model.haptic?.kind == .error)
        let item = try #require(model.item(id))
        #expect(!item.isEntry)
        #expect(item.rowActions == [.saveAsNew, .saveWithWeight, .link])
        inventory.createError = nil
        #expect(await model.saveAsNew(id))
        #expect(model.item(id)?.statusText == "Created in Bambuddy")
    }

    @Test func saveAsNewIsRefusedWhereItIsNotOffered() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(!(await model.saveAsNew(id)))
        #expect(!(await model.saveAsNew(UUID())))
        #expect(inventory.creates.isEmpty)
    }

    @Test func saveWithWeightRevealsAndFocusesTheEntry() async throws {
        let (model, session) = makeModel()
        let id = try await newSpool(model, session)

        model.revealEntry(id)

        let item = try #require(model.item(id))
        #expect(item.isEntry)
        #expect(item.isWaiting)
        #expect(item.savesNewSpool)
        #expect(model.focusedRow == id)
        #expect(model.focusedField == id)
        // label 1000 + the settings' core 250, in the settings' gross
        #expect(model.weightText(for: id) == "1250")
        #expect(model.canSave(id))
        // the next snapshot does not count it as newly waiting
        model.apply(await session.snapshot)
        #expect(model.focusedRow == id)
        #expect(model.item(id)?.isEntry == true)
    }

    @Test func aRevealTakesFocusEvenFromATypedRow() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndNew(model, session)
        model.setWeightText("9", for: rows.known)

        model.revealEntry(rows.new)

        #expect(model.focusedRow == rows.new)
        #expect(model.focus.hintedRow == nil)
    }

    @Test func hidingTheEntryDropsTheDraftAndPassesFocusOn() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndNew(model, session)
        model.revealEntry(rows.new)
        model.setWeightText("900", for: rows.new)
        model.setMode(.net, for: rows.new)

        model.hideEntry(rows.new)

        let item = try #require(model.item(rows.new))
        #expect(!item.isEntry)
        #expect(!item.isWaiting)
        #expect(!model.draft(for: rows.new).touched)
        #expect(model.mode(for: rows.new) == .gross)
        #expect(model.focusedRow == rows.known)
        // revealed again: the suggestion, not the old draft
        model.revealEntry(rows.new)
        #expect(model.weightText(for: rows.new) == "1250")
    }

    @Test func hidingTheOnlyEntryKeepsTheSelection() async throws {
        let (model, session) = makeModel()
        let id = try await newSpool(model, session)
        model.revealEntry(id)

        model.hideEntry(id)

        #expect(model.focusedRow == id)
        #expect(model.focusedField == nil)
    }

    @Test func revealAndHideIgnoreRowsWithoutAnOptionalEntry() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [knownSpool()]))
        let known = await session.record(try scan("s-1"))
        _ = await session.lookup(row: known)
        let blank = await session.record(try scan("s-2", "scan_ntag"))
        _ = await session.lookup(row: blank)
        model.apply(await session.snapshot)
        model.focusedRow = blank

        model.revealEntry(blank)
        model.revealEntry(known)
        model.hideEntry(known)
        model.revealEntry(UUID())

        #expect(model.item(blank)?.isEntry == false)
        #expect(model.item(known)?.isEntry == true)
        #expect(model.focusedRow == blank)
    }

    @Test func saveOnARevealedNewSpoolCreatesItAndRecordsTheWeight() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = try await newSpool(model, session)
        model.revealEntry(id)
        model.setWeightText("1100", for: id)

        #expect(await model.save(id))

        #expect(inventory.creates.count == 1)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 1100)])
        let item = try #require(model.item(id))
        #expect(item.isReopenable)
        #expect(!item.isEntry)
        // a reopen is a known spool's entry, not the card's
        await model.reopen(id)
        #expect(model.item(id)?.isEntry == true)
        #expect(model.item(id)?.revealsEntry == false)
    }

    @Test func aFailedSaveOnARevealedNewSpoolKeepsTheEntry() async throws {
        let inventory = FakeInventory()
        inventory.createError = .network("timed out")
        let (model, session) = makeModel(inventory)
        let id = try await newSpool(model, session)
        model.revealEntry(id)
        model.setWeightText("1100", for: id)

        #expect(!(await model.save(id)))

        let item = try #require(model.item(id))
        #expect(item.isError)
        #expect(item.isEntry)
        #expect(item.savesNewSpool)
        #expect(model.weightText(for: id) == "1100")
        #expect(model.focusedField == id)
        inventory.createError = nil
        #expect(await model.save(id))
        #expect(inventory.updates == [.update(spoolId: 100, gross: 1100)])
    }

    @Test func aCreatedOnScanRowWaitsForNothingUntilSetWeight() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)

        #expect(model.item(id)?.statusText == "Created in Bambuddy")
        #expect(model.item(id)?.isEntry == false)
        #expect(model.focusedRow == nil)

        model.revealEntry(id)
        #expect(model.focusedField == id)
        #expect(model.weightText(for: id) == "1250")
        model.setWeightText("1100", for: id)
        #expect(await model.save(id))

        #expect(inventory.creates.count == 1)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 1100)])
        #expect(model.item(id)?.isReopenable == true)
    }

    @Test func aFailedSetWeightKeepsTheEntryAndLink() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        model.revealEntry(id)
        model.setWeightText("1100", for: id)
        inventory.updateError = .network("timed out")

        #expect(!(await model.save(id)))

        let item = try #require(model.item(id))
        #expect(item.isError)
        #expect(item.isEntry)
        #expect(item.offersLinkExisting)
        #expect(item.rowActions == [.link])
        #expect(model.weightText(for: id) == "1100")
    }

    @Test func afterASaveFocusSkipsANewSpool() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndNew(model, session, newFirst: true)
        #expect(model.focusedRow == rows.known)

        model.setWeightText("900", for: rows.known)
        #expect(await model.save(rows.known))

        // nothing else waits: the selection stays on the saved row
        #expect(model.focusedRow == rows.known)
        #expect(model.focusedField == nil)
    }

    @Test func afterASaveFocusSkipsACreatedRow() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        _ = await session.handleScan(try scan("s-0", autosave: true))
        let known = await session.record(try scan("s-1", "scan_ntag"))
        _ = await session.lookup(row: known)
        model.apply(await session.snapshot)
        #expect(model.items.map(\.statusText) == ["Enter weight", "Created in Bambuddy"])
        #expect(model.focusedRow == known)

        model.setWeightText("900", for: known)
        #expect(await model.save(known))

        #expect(model.focusedRow == known)
    }

    @Test func afterASaveFocusMovesToARevealedEntry() async throws {
        let (model, session) = makeModel(FakeInventory(spools: [try ntagSpool()]))
        let rows = try await knownAndNew(model, session, newFirst: true)
        model.revealEntry(rows.new)
        model.focusedRow = rows.known

        model.setWeightText("900", for: rows.known)
        #expect(await model.save(rows.known))

        #expect(model.focusedRow == rows.new)
    }

    @Test func aRescanForgetsTheReveal() async throws {
        let (model, session) = makeModel()
        let id = try await newSpool(model, session)
        model.revealEntry(id)

        #expect(await session.record(try scan("s-2")) == id)
        model.apply(await session.snapshot)
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(model.item(id)?.statusText == "New spool")
        #expect(model.item(id)?.isEntry == false)
    }

    @Test func theFlipperWeighingANewSpoolShowsSavingWithoutActions() async throws {
        let inventory = FakeInventory()
        inventory.updateDelay = .milliseconds(300)
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try fixtureScan())
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        #expect(model.item(id)?.statusText == "New spool")

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

@Suite("FeedItem: where the card's actions go")
struct NewSpoolCardLayoutTests {
    /// iPhone: Save as new full width over Save with weight… and Link as
    /// capsules; iPad: Link under the status, the other two as pills.
    @Test func aNewSpoolLeadsWithSaveAsNew() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true)))
        #expect(item.cardLeadAction == .saveAsNew)
        #expect(item.cardCapsuleActions == [.saveWithWeight, .link])
        #expect(item.cardProminentCapsule == nil)
        #expect(item.tableTrailingActions == [.saveAsNew, .saveWithWeight])
        #expect(item.tableStatusActions == [.link])
        #expect(item.tableProminentAction == .saveAsNew)
        #expect(!item.offersCancel)
    }

    @Test func aCreatedRowLeadsWithSetWeight() throws {
        let item = FeedItem(try createdRow())
        #expect(item.cardLeadAction == .setWeight)
        #expect(item.cardCapsuleActions == [.link])
        #expect(item.cardProminentCapsule == nil)
        #expect(item.tableTrailingActions == [.setWeight])
        #expect(item.tableStatusActions == [.link])
        #expect(item.tableProminentAction == .setWeight)
    }

    /// The Flipper asked to link: Link leads on the iPhone and stays under
    /// the status on the iPad, where no pill is prominent then.
    @Test func aLinkRequestLeadsWithLink() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true), request: .link))
        #expect(item.cardLeadAction == .link)
        #expect(item.cardCapsuleActions == [.saveAsNew, .saveWithWeight])
        #expect(item.tableTrailingActions == [.saveAsNew, .saveWithWeight])
        #expect(item.tableStatusActions == [.link])
        #expect(item.tableProminentAction == nil)
    }

    /// A revealed entry: Cancel and Link beside it, nothing prominent but Save.
    @Test func aRevealedEntryOffersCancelAndLink() throws {
        for revealed in [
            FeedItem(try row(status: .unknown(prefill: true)), entryRevealed: true),
            FeedItem(try createdRow(), entryRevealed: true),
        ] {
            #expect(revealed.offersCancel)
            #expect(revealed.cardLeadAction == nil)
            #expect(revealed.cardCapsuleActions == [.link])
            #expect(revealed.cardProminentCapsule == nil)
            #expect(revealed.tableTrailingActions.isEmpty)
            #expect(revealed.tableStatusActions == [.link])
        }
    }

    /// Rows without an optional entry keep the two equal capsules (pills
    /// on the iPad), the first one prominent.
    @Test func otherUnknownRowsKeepTwoCapsules() throws {
        let blank = FeedItem(try row(status: .unknown(prefill: false), "scan_ntag"))
        #expect(blank.cardLeadAction == nil)
        #expect(blank.cardCapsuleActions == [.newForm, .link])
        #expect(blank.cardProminentCapsule == .newForm)
        #expect(blank.tableTrailingActions == [.newForm, .link])
        #expect(blank.tableStatusActions.isEmpty)
        #expect(blank.tableProminentAction == .newForm)

        let link = FeedItem(try row(status: .unknown(prefill: false), request: .link, "scan_ntag"))
        #expect(link.cardCapsuleActions == [.link, .newForm])
        #expect(link.cardProminentCapsule == .link)
        #expect(link.tableProminentAction == .link)

        let deleted = FeedItem(try row(status: .deleted))
        #expect(deleted.cardCapsuleActions == [.saveAsNew, .link])
        #expect(deleted.cardProminentCapsule == .saveAsNew)
        #expect(!deleted.offersCancel)
    }

    /// Known spools have no actions and no Cancel; Esc leaves their entry.
    @Test func knownSpoolsOfferNoCancel() throws {
        let item = FeedItem(try row(status: .awaitingWeight, spool: knownSpool()))
        #expect(item.isEntry)
        #expect(!item.offersCancel)
        #expect(item.cardCapsuleActions.isEmpty)
        #expect(item.tableTrailingActions.isEmpty)
        #expect(item.tableStatusActions.isEmpty)
    }
}
