import Foundation
import Testing
@testable import FliBuddyCore

/// A clock the tests move by hand, e.g. from inside a Bambuddy call.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private func scan(_ scanId: String, _ name: String = "scan_mfc") throws -> Scan {
    var scan = try fixtureScan(name)
    scan.scanId = scanId
    return scan
}

private func row(status: FeedRow.Status, spool: Spool? = knownSpool(), request: FeedRow.HostRequest? = nil) throws -> FeedRow {
    var row = FeedRow(scanId: "s-1", dump: try fixtureScan().tag, spool: spool, status: status)
    row.request = request
    return row
}

@MainActor
private func makeModel(
    _ inventory: FakeInventory = FakeInventory(spools: [knownSpool()]), clock: TestClock = TestClock()
) -> (FeedViewModel, Session) {
    let session = Session(settings: testSettings, inventory: inventory, now: { clock.now })
    return (FeedViewModel(session: session, settings: testSettings), session)
}

@Suite("FeedItem: weight readout and states")
struct FeedItemRulesTests {
    @Test func theReadoutSaysWhatASaveRecords() {
        #expect(FeedItem.readout(value: 915, mode: .gross, core: 325)
            == FeedItem.Readout(text: "Saves 590 g left · 915 \u{2212} 325 g core", isError: false))
        #expect(FeedItem.readout(value: 590, mode: .net, core: 325)
            == FeedItem.Readout(text: "Saves 590 g left", isError: false))
        #expect(FeedItem.readout(value: nil, mode: .gross, core: 325)
            == FeedItem.Readout(text: "Type the scale reading", isError: false))
        #expect(FeedItem.readout(value: nil, mode: .net, core: 325)
            == FeedItem.Readout(text: "Type the scale reading", isError: false))
        #expect(FeedItem.readout(value: 300, mode: .gross, core: 325)
            == FeedItem.Readout(text: "Below the core weight (325 g)", isError: true))
        #expect(FeedItem.readout(value: 325, mode: .gross, core: 325)
            == FeedItem.Readout(text: "Saves 0 g left · 325 \u{2212} 325 g core", isError: false))
        #expect(FeedItem.readout(value: 0, mode: .net, core: 325).isError == false)
    }

    @Test func eachStateHasItsPhraseSymbolAndTint() throws {
        var saved = try row(status: .saved)
        saved.savedBy = .host
        var timedOut = try row(status: .savedAfterTimeout)
        timedOut.savedBy = .host
        let cases: [(FeedRow, String, StatusSymbol, StatusTint)] = [
            (try row(status: .scanned, spool: nil), "Looking up", .progress, .secondary),
            (try row(status: .awaitingWeight), "Enter weight", .symbol("scalemass"), .blue),
            (try row(status: .saving), "Saving\u{2026}", .progress, .secondary),
            (saved, "Saved 484 g left · by host", .symbol("checkmark.circle.fill"), .green),
            (timedOut, "Saved 484 g left · by host", .symbol("checkmark.circle.fill"), .green),
            (try row(status: .created), "Created in Bambuddy", .symbol("plus.circle.fill"), .green),
            (try row(status: .error("Bambuddy unreachable")), "Error: Bambuddy unreachable",
             .symbol("exclamationmark.triangle.fill"), .red),
            (try row(status: .unknown(prefill: false), spool: nil), "Not in Bambuddy; tag has no material",
             .symbol("questionmark.circle"), .secondary),
            (try row(status: .unknown(prefill: false), spool: nil, request: .create), "Flipper asks to create it here",
             .symbol("dot.radiowaves.left.and.right"), .blue),
            (try row(status: .unknown(prefill: true), spool: nil, request: .link), "Flipper asks to link it here",
             .symbol("dot.radiowaves.left.and.right"), .blue),
        ]
        for (row, text, symbol, tint) in cases {
            let item = FeedItem(row)
            #expect(item.statusText == text, "\(row.status)")
            #expect(item.statusSymbol == symbol, "\(row.status)")
            #expect(item.statusTint == tint, "\(row.status)")
            #expect(item.isError == (tint == .red), "\(row.status)")
        }
    }

    @Test func entryAndReopenableStates() throws {
        let entry: [FeedRow.Status] = [.awaitingWeight, .saving, .created, .error("boom")]
        for status in entry {
            #expect(FeedItem(try row(status: status)).isEntry, "\(status)")
            #expect(!FeedItem(try row(status: status)).isReopenable, "\(status)")
        }
        for status in [FeedRow.Status.saved, .savedAfterTimeout] {
            #expect(!FeedItem(try row(status: status)).isEntry, "\(status)")
            #expect(FeedItem(try row(status: status)).isReopenable, "\(status)")
        }
        for status in [FeedRow.Status.scanned, .unknown(prefill: true), .unknown(prefill: false)] {
            #expect(!FeedItem(try row(status: status, spool: nil)).isEntry, "\(status)")
            #expect(!FeedItem(try row(status: status, spool: nil)).isReopenable, "\(status)")
        }
        // an error without a spool offers New and Link, not a weight
        #expect(!FeedItem(try row(status: .error("boom"), spool: nil)).isEntry)
        #expect(FeedItem(try row(status: .error("boom"), spool: nil)).offersUnknownActions)
        #expect(FeedItem(try row(status: .saving)).isSaving)
        #expect(FeedItem(try row(status: .created)).isCreated)
    }

    @Test func onlyATimedOutSaveHasTheNote() throws {
        #expect(FeedItem(try row(status: .savedAfterTimeout)).timeoutNote
            == "Flipper timed out after 10 s and showed an error; the save went through.")
        #expect(FeedItem(try row(status: .saved)).timeoutNote == nil)
    }

    @Test func theAccessibilityHeaderReadsAsOneSentence() throws {
        #expect(FeedItem(try row(status: .awaitingWeight)).accessibilityHeader
            == "PLA Basic, Jade White, 484 grams left of 1000, Enter weight")
        // an unnamed colour is left out rather than read as hex
        let unknown = FeedItem(try row(status: .unknown(prefill: true), spool: nil))
        #expect(unknown.accessibilityHeader == "\(unknown.title), label 1000 grams, Not in Bambuddy")
    }
}

@MainActor
@Suite("FeedViewModel: drafts, reopen and create on scan")
struct FeedViewModelRulesTests {
    @Test func theFieldStartsWithTheSuggestionAndAModeSwitchConvertsIt() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "734", touched: false, mode: .gross))
        model.setMode(.net, for: id)
        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "484", touched: false, mode: .net))
        #expect(model.readout(for: id)?.text == "Saves 484 g left")
    }

    @Test func aModeSwitchKeepsATypedValue() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("900", for: id)
        model.setMode(.net, for: id)

        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "900", touched: true, mode: .net))
    }

    @Test func saveIsDisabledBelowTheCoreInGrossAndWhileSaving() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("200", for: id)
        #expect(model.readout(for: id) == FeedItem.Readout(text: "Below the core weight (250 g)", isError: true))
        #expect(!model.canSave(id))
        model.setMode(.net, for: id)
        #expect(model.canSave(id))

        inventory.updateDelay = .milliseconds(300)
        let saving = Task { await model.save(id) }
        #expect(await eventually { await session.rows.first?.status == .saving })
        model.apply(await session.snapshot)
        #expect(model.items.first?.statusText == "Saving\u{2026}")
        #expect(!model.canSave(id))
        await saving.value
    }

    @Test func aSavedRowReopensForAReweighWithTheSavedValueAsBase() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)
        model.setWeightText("900", for: id)
        await model.save(id)
        #expect(model.item(id)?.isReopenable == true)
        #expect(!model.canSave(id))

        await model.reopen(id)

        let item = try #require(model.item(id))
        #expect(item.isEntry)
        #expect(item.statusText == "Enter weight")
        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "900", touched: false, mode: .gross))
    }

    @Test func reopenIgnoresARowThatIsNotSaved() async throws {
        let (model, session) = makeModel(FakeInventory())
        let id = await session.record(try scan("s-1", "scan_ntag"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        await model.reopen(id)

        #expect(model.item(id)?.statusText == "Not in Bambuddy; tag has no material")
    }

    @Test func anUnknownBambuTagIsCreatedOnScanAndOpensWithLabelPlusCore() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)

        let lookup = await session.handleScan(try scan("s-1"))
        model.apply(await session.snapshot)

        let tag = TagParser.parse(try fixtureScan().tag)
        let newSpool = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(inventory.creates == [.create(newSpool)])
        // the Flipper goes to weight entry for the new spool
        #expect(lookup.status == .found)
        #expect(lookup.spoolId == 100)
        #expect(lookup.defaults == Lookup.Defaults(gross: 1250, label: 1000, core: 250))
        let item = try #require(model.items.first)
        #expect(item.statusText == "Created in Bambuddy")
        #expect(item.savedByText == "by host")
        #expect(item.isEntry)
        #expect(item.isCreated)
        #expect(model.draft(for: item.id) == FeedViewModel.Draft(value: "1250", touched: false, mode: .gross))
        #expect(model.readout(for: item.id)?.text == "Saves 1000 g left · 1250 \u{2212} 250 g core")

        // Save sends the weight as a separate request
        model.setWeightText("1100", for: item.id)
        await model.save(item.id)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 1100)])
    }

    @Test func aRescanFindsTheSpoolCreatedOnTheFirstScan() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)

        _ = await session.handleScan(try scan("s-1"))
        let again = await session.handleScan(try scan("s-2"))
        model.apply(await session.snapshot)

        #expect(inventory.creates.count == 1)
        #expect(again.status == .found)
        #expect(again.spoolId == 100)
        #expect(model.items.count == 1)
        #expect(model.items.first?.statusText == "Enter weight")
    }

    @Test func aFailedCreateOnScanShowsTheErrorWithNewAsTheRetry() async throws {
        let inventory = FakeInventory()
        inventory.createError = .network("timed out")
        let (model, session) = makeModel(inventory)

        let lookup = await session.handleScan(try scan("s-1"))
        model.apply(await session.snapshot)

        // the Flipper keeps its own New
        #expect(lookup.status == .unknown)
        #expect(lookup.prefill == true)
        let item = try #require(model.items.first)
        #expect(item.statusText == "Error: \(BambuddyError.network("timed out").localizedDescription)")
        #expect(!item.isEntry)
        #expect(item.offersUnknownActions)
        #expect(item.hasPrefill)

        inventory.createError = nil
        #expect(await model.createFromTag(item.id))
        #expect(model.items.first?.statusText == "Created in Bambuddy")
        #expect(inventory.creates.count == 2)
    }

    @Test func linkingACreatedRowDeletesTheCreatedSpoolThenLinks() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1"))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)

        #expect(await model.link(id, toSpool: 7))

        let tag = TagParser.parse(try fixtureScan().tag)
        #expect(Array(inventory.calls.suffix(2)) == [.delete(spoolId: 100), .link(spoolId: 7, TagLink(tag: tag))])
        #expect(inventory.spools.map(\.id) == [7])
        let item = try #require(model.items.first)
        #expect(item.spoolId == 7)
        #expect(item.statusText == "Enter weight")
        #expect(!item.isCreated)
        #expect(model.error(for: id) == nil)
    }

    @Test func aFailedDeleteKeepsTheCreatedSpoolAndSaysSo() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1"))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        inventory.deleteError = .http(status: 500, message: "boom")

        #expect(!(await model.link(id, toSpool: 7)))

        let reason = BambuddyError.http(status: 500, message: "boom").localizedDescription
        let message = "Spool 100 created on scan could not be deleted, so the tag stays on it: \(reason)"
        #expect(model.error(for: id) == message)
        #expect(!inventory.calls.contains { if case .link = $0 { true } else { false } })
        let item = try #require(model.items.first)
        #expect(item.spoolId == 100)
        #expect(item.statusText == "Error: \(message)")
        // the weight can still be saved on the created spool, and Link retried
        #expect(item.isEntry)
        inventory.deleteError = nil
        #expect(await model.link(id, toSpool: 7))
        #expect(model.items.first?.spoolId == 7)
    }

    @Test func aFailedLinkAfterTheDeleteLeavesTheRowWithoutASpool() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1"))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        inventory.linkError = .network("timed out")

        #expect(!(await model.link(id, toSpool: 7)))

        let item = try #require(model.items.first)
        #expect(item.spoolId == nil)
        #expect(item.offersUnknownActions)
        #expect(inventory.spools.map(\.id) == [7])
    }

    @Test func linkingAKnownRowDeletesNothing() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1", "scan_ntag"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(await model.link(id, toSpool: 7))

        #expect(!inventory.calls.contains { if case .delete = $0 { true } else { false } })
    }

    @Test func aRescanMovesTheRowToTheTopWithoutADuplicate() async throws {
        let (model, session) = makeModel()
        let first = await session.record(try scan("s-1"))
        _ = await session.lookup(row: first)
        _ = await session.record(try scan("s-2", "scan_ntag"))
        try await session.saveWeight(row: first, grams: 900, mode: .gross)

        _ = await session.handleScan(try scan("s-3"))
        model.apply(await session.snapshot)

        #expect(model.items.map(\.scanId) == ["s-3", "s-2"])
        let item = try #require(model.items.first)
        #expect(item.id == first)
        // reopened for a weight
        #expect(item.statusText == "Enter weight")
        #expect(item.isEntry)
    }

    @Test func anIntentOfTheEarlierScanStillFindsTheMovedRow() async throws {
        let (_, session) = makeModel()
        _ = await session.handleScan(try scan("s-000012"))
        _ = await session.handleScan(try scan("s-2"))

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross, scanId: "s-000012"))

        #expect(result.ok)
        #expect(await session.rows.count == 1)
    }

    @Test func aFlipperSaveClearsTheHostDraftAndSaysByFlipper() async throws {
        let (model, session) = makeModel()
        _ = await session.handleScan(try scan("s-000012"))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        model.setWeightText("900", for: id)

        _ = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))
        model.apply(await session.snapshot)

        #expect(model.items.first?.statusText == "Saved 484 g left · by Flipper")
        #expect(!model.draft(for: id).touched)
    }
}

@Suite("Session: saving and timeouts")
struct SessionSavingTests {
    @Test func aFlipperWeighShowsSavingWhileBambuddyWorks() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateDelay = .milliseconds(300)
        let session = Session(settings: testSettings, inventory: inventory)
        _ = await session.handleScan(try fixtureScan())

        let pending = Task { await session.handleIntent(try weighIntent(grams: 734, mode: .gross)) }
        #expect(await eventually { await session.rows.first?.status == .saving })
        #expect(try await pending.value.ok)
        #expect(await session.rows.first?.status == .saved)
    }

    @Test func aWeighSavedAfterTheFlipperGaveUpIsMarked() async throws {
        let clock = TestClock()
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.onUpdate = { clock.advance(by: Session.flipperResultTimeout + 1) }
        let session = Session(settings: testSettings, inventory: inventory, now: { clock.now })
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        let row = try #require(await session.rows.first)
        #expect(row.status == .savedAfterTimeout)
        #expect(row.savedBy == .host)
        #expect(FeedItem(row).timeoutNote != nil)
    }

    @Test func aWeighWithinTheTimeoutIsAPlainSave() async throws {
        let clock = TestClock()
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.onUpdate = { clock.advance(by: Session.flipperResultTimeout - 1) }
        let session = Session(settings: testSettings, inventory: inventory, now: { clock.now })
        _ = await session.handleScan(try fixtureScan())

        _ = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        let row = try #require(await session.rows.first)
        #expect(row.status == .saved)
        #expect(row.savedBy == .flipper)
    }

    @Test func aSlowHostSaveIsNeverATimeout() async throws {
        let clock = TestClock()
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.onUpdate = { clock.advance(by: 60) }
        let session = Session(settings: testSettings, inventory: inventory, now: { clock.now })
        _ = await session.handleScan(try fixtureScan())
        let id = try #require(await session.rows.first?.id)

        try await session.saveWeight(row: id, grams: 734, mode: .gross)

        #expect(await session.rows.first?.status == .saved)
    }

    @Test func twoTagsOfOneSpoolShareARow() throws {
        let a = ParsedTag(kind: .bambu, uid: "5A3C9E21", trayUuid: "A1B2C3D4E5F60718293A4B5C6D7E8F90")
        let b = ParsedTag(kind: .bambu, uid: "11223344", trayUuid: "A1B2C3D4E5F60718293A4B5C6D7E8F90")
        let other = ParsedTag(kind: .bambu, uid: "11223344", trayUuid: "0123456789ABCDEF0123456789ABCDEF")
        #expect(Session.sameTag(a, b))
        #expect(Session.sameTag(b, other))
        #expect(!Session.sameTag(a, other))
        #expect(Session.sameTag(ParsedTag(kind: .ntag, uid: "04a1"), ParsedTag(kind: .ntag, uid: "04A1")))
        #expect(!Session.sameTag(ParsedTag(kind: .ntag, uid: "04A1"), ParsedTag(kind: .bambu, uid: "04A1")))
    }
}
