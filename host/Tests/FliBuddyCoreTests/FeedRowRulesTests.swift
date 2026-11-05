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

private func scan(_ scanId: String, _ name: String = "scan_mfc", autosave: Bool = false) throws -> Scan {
    var scan = try fixtureScan(name)
    scan.scanId = scanId
    scan.autosave = autosave
    return scan
}

private func row(
    status: FeedRow.Status, spool: Spool? = knownSpool(), request: FeedRow.HostRequest? = nil, _ name: String = "scan_mfc"
) throws -> FeedRow {
    var row = FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: status)
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
        #expect(FeedItem.readout(value: 832, mode: .gross, core: 242)
            == FeedItem.Readout(text: "Saves 590 g left · 832 \u{2212} 242 g core", isError: false, tile: "Saves 590 g"))
        #expect(FeedItem.readout(value: 590, mode: .net, core: 242)
            == FeedItem.Readout(text: "Saves 590 g left", isError: false, tile: "Saves 590 g"))
        #expect(FeedItem.readout(value: nil, mode: .gross, core: 242)
            == FeedItem.Readout(text: "Type the scale reading", isError: false))
        #expect(FeedItem.readout(value: nil, mode: .net, core: 242)
            == FeedItem.Readout(text: "Type the scale reading", isError: false))
        #expect(FeedItem.readout(value: 200, mode: .gross, core: 242)
            == FeedItem.Readout(text: "Below the core weight (242 g)", isError: true, tile: "Below core"))
        #expect(FeedItem.readout(value: 242, mode: .gross, core: 242)
            == FeedItem.Readout(text: "Saves 0 g left · 242 \u{2212} 242 g core", isError: false, tile: "Saves 0 g"))
        #expect(FeedItem.readout(value: 0, mode: .net, core: 242).isError == false)
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
            (try row(status: .created), "Added to Bambuddy", .symbol("plus.circle.fill"), .green),
            (try row(status: .updating), "Updating\u{2026}", .progress, .secondary),
            (try row(status: .markedNew), "Marked as new · 484 g left", .symbol("arrow.counterclockwise.circle.fill"), .green),
            (try row(status: .markedEmpty), "Marked as empty · archived", .symbol("archivebox"), .secondary),
            (try row(status: .deleted, spool: nil), "Deleted from Bambuddy", .symbol("trash"), .secondary),
            (try row(status: .error("Bambuddy unreachable")), "Error: Bambuddy unreachable",
             .symbol("exclamationmark.triangle.fill"), .red),
            (try row(status: .unknown(prefill: false), spool: nil), "Not in Bambuddy; tag has no material",
             .symbol("questionmark.circle"), .secondary),
            (try row(status: .unknown(prefill: true), spool: nil), "Not in Bambuddy", .symbol("questionmark.circle"),
             .secondary),
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
        let entry: [FeedRow.Status] = [.awaitingWeight, .saving, .updating, .error("boom")]
        for status in entry {
            #expect(FeedItem(try row(status: status)).isEntry, "\(status)")
            #expect(!FeedItem(try row(status: status)).isReopenable, "\(status)")
        }
        // Added to Bambuddy reopens like a saved row: the design's New adds
        // the spool at its label weight and asks for no weight
        for status in [FeedRow.Status.saved, .savedAfterTimeout, .created, .markedNew, .markedEmpty] {
            #expect(!FeedItem(try row(status: status)).isEntry, "\(status)")
            #expect(!FeedItem(try row(status: status)).isWaiting, "\(status)")
            #expect(FeedItem(try row(status: status)).isReopenable, "\(status)")
        }
        for status in [FeedRow.Status.scanned, .deleted] {
            #expect(!FeedItem(try row(status: status, spool: nil)).isEntry, "\(status)")
            #expect(!FeedItem(try row(status: status, spool: nil)).isReopenable, "\(status)")
        }
        // a tag without material and no spool: New and Link, no weight
        for status in [FeedRow.Status.unknown(prefill: false), .error("boom")] {
            #expect(!FeedItem(try row(status: status, spool: nil, "scan_ntag")).isEntry, "\(status)")
            #expect(FeedItem(try row(status: status, spool: nil, "scan_ntag")).offersUnknownActions, "\(status)")
        }
        // a Bambu tag no spool carries (Auto-save new off): New and Link,
        // never a weight field; a Flipper weigh on it saves without one
        for status in [FeedRow.Status.unknown(prefill: true), .saving, .error("boom")] {
            let item = FeedItem(try row(status: status, spool: nil))
            #expect(!item.isEntry, "\(status)")
            #expect(!item.isWaiting, "\(status)")
            #expect(item.offersUnknownActions, "\(status)")
            #expect(!item.isReopenable, "\(status)")
        }
        #expect(FeedItem(try row(status: .saving)).isSaving)
        #expect(FeedItem(try row(status: .updating)).isSaving)
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

@Suite("FeedItem: row display strings")
struct FeedItemDisplayTests {
    @Test func theColourLineJoinsTheColourNameCodeAndWhatIsLeft() throws {
        #expect(FeedItem(try row(status: .awaitingWeight)).detailText == "Jade White · 10100 · 484 g left of 1000")
        // an unnamed colour is left out, never shown as hex
        let unnamed = FeedItem(try row(status: .awaitingWeight, spool: knownSpool(colorName: nil)))
        #expect(unnamed.colorName == nil)
        #expect(unnamed.detailText == "10100 · 484 g left of 1000")
        // an unknown tag with prefill shows its label weight
        var tagged = try row(status: .unknown(prefill: true), spool: nil)
        #expect(FeedItem(tagged).detailText == "10100 · label 1000 g")
        tagged.colorName = "Bambu Green"
        #expect(FeedItem(tagged).detailText == "Bambu Green · 10100 · label 1000 g")
        // a blank tag has nothing to say
        let blank = FeedItem(FeedRow(scanId: "s-2", dump: try fixtureScan("scan_ntag").tag, status: .unknown(prefill: false)))
        #expect(blank.detailText == "")
    }

    @Test func aBlankTagIsTitledByItsUIDLengthAndPrefix() throws {
        let blank = FeedItem(FeedRow(scanId: "s-2", dump: try fixtureScan("scan_ntag").tag, status: .unknown(prefill: false)))
        #expect(blank.title == "NTAG 7-byte UID 0411\u{2026}")
        #expect(blank.uid == "04112233445566")
        #expect(FeedItem.blankTitle(uid: "04A2B3C4") == "NTAG 4-byte UID 04A2\u{2026}")
        #expect(FeedItem.blankTitle(uid: "04A2") == "NTAG 2-byte UID 04A2")
    }

    @Test func theRowShowsTheUIDUnderTheTitle() throws {
        #expect(FeedItem(try row(status: .awaitingWeight)).uid == "5A3C9E21")
    }

    @Test func theWeightFieldIsLabelledByItsMode() {
        #expect(FeedItem.weightFieldLabel(mode: .gross) == "Gross weight, grams")
        #expect(FeedItem.weightFieldLabel(mode: .net) == "Net weight, grams")
    }

    @Test func theWeightFieldShowsItsModeWord() {
        #expect(FeedItem.modeWord(.gross) == "gross")
        #expect(FeedItem.modeWord(.net) == "net")
    }

    @Test func everyStateInTheSpecTableReadsAsSpecified() throws {
        var saved = try row(status: .saved)
        saved.savedBy = .flipper
        var timedOut = try row(status: .savedAfterTimeout)
        timedOut.savedBy = .host
        // status · entry block · reopenable · timeout note
        let cases: [(FeedRow, String, Bool, Bool, Bool)] = [
            (try row(status: .scanned, spool: nil), "Looking up", false, false, false),
            (try row(status: .awaitingWeight), "Enter weight", true, false, false),
            (try row(status: .saving), "Saving\u{2026}", true, false, false),
            (saved, "Saved 484 g left · by Flipper", false, true, false),
            (timedOut, "Saved 484 g left · by host", false, true, true),
            (try row(status: .created), "Added to Bambuddy", false, true, false),
            (try row(status: .error("Bambuddy unreachable")), "Error: Bambuddy unreachable", true, false, false),
            (try row(status: .unknown(prefill: true), spool: nil), "Not in Bambuddy", false, false, false),
            (try row(status: .unknown(prefill: false), spool: nil, "scan_ntag"), "Not in Bambuddy; tag has no material",
             false, false, false),
            (try row(status: .unknown(prefill: false), spool: nil, request: .create, "scan_ntag"),
             "Flipper asks to create it here", false, false, false),
            (try row(status: .unknown(prefill: true), spool: nil, request: .link), "Flipper asks to link it here",
             false, false, false),
            (try row(status: .updating), "Updating\u{2026}", true, false, false),
        ]
        for (row, status, entry, reopenable, note) in cases {
            let item = FeedItem(row)
            #expect(item.statusText == status, "\(row.status)")
            #expect(item.isEntry == entry, "\(row.status)")
            #expect(item.isReopenable == reopenable, "\(row.status)")
            #expect((item.timeoutNote != nil) == note, "\(row.status)")
            #expect(item.accessibilityHeader.hasSuffix(status), "\(row.status)")
        }
    }

    @Test func theAccessibilityHeaderOfEachKindOfRow() throws {
        #expect(FeedItem(try row(status: .created)).accessibilityHeader
            == "PLA Basic, Jade White, 484 grams left of 1000, Added to Bambuddy")
        var named = try row(status: .unknown(prefill: true), spool: nil, request: .create)
        named.colorName = "Bambu Green"
        let tagged = FeedItem(named)
        #expect(tagged.accessibilityHeader
            == "\(tagged.title), Bambu Green, label 1000 grams, Flipper asks to create it here")
        let blank = FeedItem(FeedRow(scanId: "s-2", dump: try fixtureScan("scan_ntag").tag, status: .unknown(prefill: false)))
        #expect(blank.accessibilityHeader == "NTAG 7-byte UID 0411\u{2026}, Not in Bambuddy; tag has no material")
    }

    /// "New…" opens the form for a tag without material; "New" adds the
    /// spool from the tag in one step. New is prominent unless the Flipper
    /// asked to link.
    @Test func newAndLinkOnAnUnknownRow() throws {
        let blank = FeedItem(FeedRow(scanId: "s-2", dump: try fixtureScan("scan_ntag").tag, status: .unknown(prefill: false)))
        #expect(blank.rowActions == [.newForm, .link])
        #expect(FeedItem.RowAction.newForm.title == "New\u{2026}")
        #expect(blank.prominentRowAction == .newForm)

        // a failed create on scan leaves the one-step New as the retry
        let failed = FeedItem(try row(status: .error("timed out"), spool: nil))
        #expect(failed.rowActions == [.new, .link])
        #expect(failed.prominentRowAction == .new)

        #expect(FeedItem(try row(status: .unknown(prefill: true), spool: nil, request: .create)).prominentRowAction == .new)
        #expect(FeedItem(try row(status: .unknown(prefill: true), spool: nil, request: .link)).prominentRowAction == .link)
        var asked = FeedRow(scanId: "s-3", dump: try fixtureScan("scan_ntag").tag, status: .unknown(prefill: false))
        asked.request = .create
        #expect(FeedItem(asked).rowActions == [.newForm, .link])
        #expect(FeedItem(asked).prominentRowAction == .newForm)
    }

    @Test func theRowCarriesTheTagAsBambuddyKeepsIt() throws {
        let bambu = FeedItem(try row(status: .unknown(prefill: true), spool: nil))
        #expect(bambu.bambuddyTagUid == "5A3C9E2100000100")
        let blank = FeedItem(FeedRow(scanId: "s-2", dump: try fixtureScan("scan_ntag").tag, status: .unknown(prefill: false)))
        #expect(blank.bambuddyTagUid == "04112233445566")
        #expect(blank.trayUuid == nil)
    }
}

@MainActor
@Suite("FeedViewModel: the Save button")
struct FeedViewModelSaveButtonTests {
    @Test func saveReadsSavingWhileTheWeightIsOnItsWay() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)
        #expect(model.saveTitle(for: id) == "Save")
        #expect(!model.isSaving(id))

        inventory.updateDelay = .milliseconds(300)
        let saving = Task { await model.save(id) }
        #expect(await eventually { await session.rows.first?.status == .saving })
        model.apply(await session.snapshot)
        #expect(model.saveTitle(for: id) == "Saving\u{2026}")
        #expect(model.isSaving(id))
        #expect(!model.canSave(id))
        _ = await saving.value
        #expect(model.saveTitle(for: id) == "Save")
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

    @Test func aModeSwitchConvertsATypedValue() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        // gross → net takes the spool's 250 g core off; net → gross adds it back
        model.setWeightText("900", for: id)
        model.setMode(.net, for: id)
        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "650", touched: true, mode: .net))
        #expect(model.readout(for: id)?.text == "Saves 650 g left")
        model.setMode(.gross, for: id)
        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "900", touched: true, mode: .gross))
        // the same mode again changes nothing
        model.setMode(.gross, for: id)
        #expect(model.weightText(for: id) == "900")
    }

    @Test func aConversionClampsToTheWeightRange() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        // below the core: net 0, as on the Flipper
        model.setWeightText("200", for: id)
        model.setMode(.net, for: id)
        #expect(model.weightText(for: id) == "0")
        model.setMode(.gross, for: id)
        #expect(model.weightText(for: id) == "250")
        // four digits at most
        model.setMode(.net, for: id)
        model.setWeightText("9900", for: id)
        model.setMode(.gross, for: id)
        #expect(model.weightText(for: id) == "9999")
        #expect(FeedViewModel.convert(100, to: .net, core: nil) == 100)
        #expect(FeedViewModel.convert(100, to: .gross, core: -5) == 100)
    }

    @Test func aModeSwitchLeavesAnEmptyFieldEmpty() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("", for: id)
        model.setMode(.net, for: id)

        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "", touched: true, mode: .net))
    }

    @Test func anUntouchedSuggestionStaysUntouchedThroughASwitch() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setMode(.net, for: id)
        model.setMode(.gross, for: id)

        #expect(model.draft(for: id) == FeedViewModel.Draft(value: "734", touched: false, mode: .gross))
    }

    @Test func saveIsDisabledBelowTheCoreInGrossAndWhileSaving() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("200", for: id)
        #expect(model.readout(for: id) == FeedItem.Readout(text: "Below the core weight (250 g)", isError: true, tile: "Below core"))
        #expect(!model.canSave(id))
        model.setMode(.net, for: id)
        #expect(model.canSave(id))

        inventory.updateDelay = .milliseconds(300)
        let saving = Task { await model.save(id) }
        #expect(await eventually { await session.rows.first?.status == .saving })
        model.apply(await session.snapshot)
        #expect(model.items.first?.statusText == "Saving\u{2026}")
        #expect(!model.canSave(id))
        _ = await saving.value
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

        let lookup = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)

        let tag = TagParser.parse(try fixtureScan().tag)
        let newSpool = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(inventory.creates == [.create(newSpool)])
        // the Flipper goes to weight entry for the new spool
        #expect(lookup.status == .found)
        #expect(lookup.spoolId == 100)
        #expect(lookup.defaults == Lookup.Defaults(gross: 1250, label: 1000, core: 250))
        let item = try #require(model.items.first)
        #expect(item.statusText == "Added to Bambuddy")
        #expect(!item.isEntry)
        #expect(item.rowActions.isEmpty)
        await model.reopen(item.id)
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

        _ = await session.handleScan(try scan("s-1", autosave: true))
        let again = await session.handleScan(try scan("s-2", autosave: true))
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

        let lookup = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)

        // the Flipper keeps its own New
        #expect(lookup.status == .unknown)
        #expect(lookup.prefill == true)
        let item = try #require(model.items.first)
        #expect(item.statusText == "Error: \(BambuddyError.network("timed out").localizedDescription)")
        // New retries
        #expect(!item.isEntry)
        #expect(item.rowActions == [.new, .link])
        #expect(item.offersUnknownActions)

        inventory.createError = nil
        #expect(await model.addNew(item.id))
        #expect(model.items.first?.statusText == "Added to Bambuddy")
        #expect(inventory.creates.count == 2)
    }

    @Test func linkingACreatedRowDeletesTheCreatedSpoolThenLinks() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)

        await model.loadLinkCandidates()
        #expect(await model.link(id, toSpool: 7))

        let tag = TagParser.parse(try fixtureScan().tag)
        #expect(Array(inventory.calls.suffix(2)) == [.delete(spoolId: 100), .link(spoolId: 7, TagLink(tag: tag))])
        #expect(inventory.spools.map(\.id) == [7])
        let item = try #require(model.items.first)
        #expect(item.spoolId == 7)
        #expect(item.statusText == "Enter weight")
        #expect(await session.rows.first?.createdSpoolId == nil)
        #expect(model.error(for: id) == nil)
    }

    @Test func aFailedDeleteKeepsTheCreatedSpoolAndSaysSo() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        inventory.deleteError = .http(status: 500, message: "boom")

        await model.loadLinkCandidates()
        #expect(!(await model.link(id, toSpool: 7)))

        let reason = BambuddyError.http(status: 500, message: "boom").localizedDescription
        let message = "Spool 100 created on scan could not be deleted, so the tag stays on it: \(reason)"
        #expect(model.error(for: id) == message)
        #expect(!inventory.calls.contains { if case .link = $0 { true } else { false } })
        let item = try #require(model.items.first)
        #expect(item.spoolId == 100)
        #expect(item.statusText == "Error: \(message)")
        // the created spool keeps its entry for a weight, and Link can be retried
        #expect(item.isEntry)
        #expect(item.rowActions.isEmpty)
        inventory.deleteError = nil
        await model.loadLinkCandidates()
        #expect(await model.link(id, toSpool: 7))
        #expect(model.items.first?.spoolId == 7)
    }

    @Test func aCreatedSpoolDeletedElsewhereStillLetsTheTagLink() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        try await inventory.deleteSpool(id: 100)

        await model.loadLinkCandidates()
        #expect(await model.link(id, toSpool: 7))

        #expect(model.items.first?.spoolId == 7)
        #expect(model.error(for: id) == nil)
    }

    @Test func aWeighedCreatedSpoolIsNotOfferedForDeletion() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        await model.reopen(id)
        model.setWeightText("1100", for: id)
        await model.save(id)
        await model.reopen(id)
        inventory.updateError = .network("timed out")
        model.setWeightText("1000", for: id)
        await model.save(id)

        // a failed re-weigh: the spool holds a saved weight, so Link would not delete it
        #expect(model.items.first?.isError == true)
        #expect(await session.rows.first?.createdSpoolId == nil)
    }

    @Test func newSettingsForgetTheSpoolCreatedOnTheOldBambuddy() async throws {
        let (model, session) = makeModel(FakeInventory())
        _ = await session.handleScan(try scan("s-1", autosave: true))
        let target = Spool(id: 100, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let other = FakeInventory(spools: [target])
        await session.reconfigure(settings: testSettings, inventory: other)
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)

        #expect(await session.rows.first?.createdSpoolId == nil)
        await model.loadLinkCandidates()
        #expect(await model.link(id, toSpool: 100))
        // spool 100 on the new Bambuddy is someone else's: it is linked, never deleted
        #expect(!other.calls.contains { if case .delete = $0 { true } else { false } })
    }

    @Test func newSettingsBetweenTheDeleteAndTheLinkLinkNothingAndReloadTheList() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let old = FakeInventory(spools: [target])
        let (model, session) = makeModel(old)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        await model.loadLinkCandidates()
        // spool 7 on the new Bambuddy is someone else's
        let other = FakeInventory(spools: [Spool(id: 7, material: "ASA", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        old.onDelete = { await session.reconfigure(settings: testSettings, inventory: other) }

        #expect(!(await model.link(id, toSpool: 7)))

        #expect(!old.calls.contains { if case .link = $0 { true } else { false } })
        #expect(!other.calls.contains { if case .link = $0 { true } else { false } })
        #expect(model.error(for: id) == SessionError.staleSpoolList.localizedDescription)
        #expect(model.linkCandidates.map(\.material) == ["ASA"])
    }

    @Test func aFailedLinkAfterTheDeleteLeavesTheRowWithoutASpool() async throws {
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [target])
        let (model, session) = makeModel(inventory)
        _ = await session.handleScan(try scan("s-1", autosave: true))
        model.apply(await session.snapshot)
        let id = try #require(model.items.first?.id)
        inventory.linkError = .network("timed out")

        await model.loadLinkCandidates()
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

        await model.loadLinkCandidates()
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
