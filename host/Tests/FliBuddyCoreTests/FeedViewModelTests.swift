import Foundation
import Testing
@testable import FliBuddyCore

/// A scan of the synthetic Bambu fixture under a new scan id.
private func scan(_ scanId: String) throws -> Scan {
    var scan = try fixtureScan()
    scan.scanId = scanId
    return scan
}

/// A row as the session would hold it, for presentation tests.
private func row(
    _ name: String = "scan_mfc", status: FeedRow.Status = .scanned, spool: Spool? = nil
) throws -> FeedRow {
    var row = FeedRow(scanId: "s-1", dump: try fixtureScan(name).tag, spool: spool, status: status)
    row.status = status
    return row
}

@MainActor
private func makeModel(_ inventory: FakeInventory = FakeInventory(spools: [knownSpool()])) -> (FeedViewModel, Session) {
    let session = Session(settings: testSettings, inventory: inventory)
    return (FeedViewModel(session: session, settings: testSettings), session)
}

@MainActor
@Suite("FeedViewModel")
struct FeedViewModelTests {
    @Test func rowsRenderNewestFirst() async throws {
        let (model, session) = makeModel()
        var other = try fixtureScan("scan_ntag")
        other.scanId = "s-3"
        other.tag.uid = "04998877665544"
        await session.record(try scan("s-1"))
        await session.record(try fixtureScan("scan_ntag"))
        await session.record(other)

        model.apply(await session.snapshot)

        #expect(model.items.map(\.scanId) == ["s-3", "s-000013", "s-1"])
    }

    @Test func observingFollowsTheSession() async throws {
        let (model, session) = makeModel()
        let observer = Task { await model.observe() }
        defer { observer.cancel() }

        await session.record(try scan("s-1"))
        #expect(await eventually { model.items.count == 1 })
        await session.clear()
        #expect(await eventually { model.items.isEmpty })
    }

    @Test func theWeightFieldAcceptsIntegersOnly() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        model.apply(await session.snapshot)

        model.setWeightText("7a3,4 g", for: id)
        #expect(model.weightText(for: id) == "734")
        model.setWeightText("-12.5", for: id)
        #expect(model.weightText(for: id) == "125")
        model.setWeightText("123456", for: id)
        #expect(model.weightText(for: id) == "1234")
        model.setWeightText("７３４", for: id)
        #expect(model.weightText(for: id) == "")
        #expect(FeedViewModel.sanitizeWeight("0734") == "0734")
        #expect(FeedViewModel.grams(from: "0734") == 734)
        #expect(FeedViewModel.grams(from: "") == nil)
    }

    @Test func saveIsEnabledOnlyWithAValue() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        // the field starts with the suggestion
        #expect(model.canSave(id))
        model.setWeightText("", for: id)
        #expect(!model.canSave(id))
        model.setWeightText("734", for: id)
        #expect(model.canSave(id))
    }

    @Test func saveNeedsAKnownSpool() async throws {
        let (model, session) = makeModel(FakeInventory())
        let id = await session.record(try fixtureScan("scan_ntag"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("734", for: id)
        #expect(!model.canSave(id))
    }

    @Test func savingSendsTheWeightAndClearsTheDraft() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("484", for: id)
        model.setMode(.net, for: id)
        await model.save(id)

        #expect(inventory.updates == [.update(spoolId: 42, gross: 734)])
        let item = try #require(model.items.first)
        #expect(item.statusText == "Saved 484 g left · by host")
        #expect(item.savedByText == "by host")
        #expect(!model.draft(for: id).touched)
        #expect(model.error(for: id) == nil)
    }

    @Test func aFailedSaveKeepsTheDraftAndShowsTheError() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateError = .network("timed out")
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        model.setWeightText("734", for: id)
        await model.save(id)

        #expect(model.weightText(for: id) == "734")
        #expect(model.error(for: id) != nil)
        #expect(model.items.first?.statusText.hasPrefix("Error: ") == true)
    }

    @Test func theModeDefaultsToTheSettingsThenTheLastSavedMode() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        model.apply(await session.snapshot)
        #expect(model.mode(for: id) == .gross)

        var settings = testSettings
        settings.defaultMode = .net
        model.settings = settings
        #expect(model.mode(for: id) == .net)

        model.setMode(.gross, for: id)
        #expect(model.mode(for: id) == .gross)
    }

    @Test func statusTextMapping() throws {
        var saved = try row(status: .saved, spool: knownSpool())
        saved.weight = FeedRow.Weight(grams: 734, mode: .gross)
        saved.savedBy = .flipper
        let cases: [(FeedRow, String)] = [
            (try row(status: .scanned), "Looking up"),
            (try row(status: .awaitingWeight, spool: knownSpool()), "Enter weight"),
            (try row(status: .unknown(prefill: true)), "Not in Bambuddy"),
            (try row(status: .unknown(prefill: false)), "Not in Bambuddy; tag has no material"),
            (try row(status: .saved, spool: knownSpool()), "Saved 484 g left"),
            (try row(status: .saved), "Saved"),
            (saved, "Saved 484 g left · by Flipper"),
            (try row(status: .created, spool: knownSpool()), "Created in Bambuddy"),
            (try row(status: .error("Bambuddy unreachable")), "Error: Bambuddy unreachable"),
        ]
        for (row, text) in cases {
            #expect(FeedItem(row).statusText == text)
        }
    }

    @Test func savedByAndHostRequestTexts() throws {
        var row = try row(status: .unknown(prefill: true))
        #expect(FeedItem(row).savedByText == nil)
        #expect(FeedItem(row).requestText == nil)
        row.request = .create
        #expect(FeedItem(row).requestText == "Flipper asks to create it here")
        row.request = .link
        #expect(FeedItem(row).requestText == "Flipper asks to link it here")
        row.savedBy = .flipper
        #expect(FeedItem(row).savedByText == "by Flipper")
        row.savedBy = .host
        #expect(FeedItem(row).savedByText == "by host")
    }

    @Test func aKnownSpoolShowsBambuddysData() throws {
        let item = FeedItem(try row(status: .awaitingWeight, spool: knownSpool()))
        #expect(item.title == "PLA Basic")
        #expect(item.colorName == "Jade White")
        #expect(item.remainingText == "484 g left of 1000")
        #expect(item.swatch == Swatch(rgba: "FFFFFFFF"))
        #expect(item.canWeigh)
        #expect(!item.offersUnknownActions)
    }

    @Test func theSuggestionIsRemainingPlusCoreInGrossAndRemainingInNet() throws {
        let weighed = FeedItem(try row(status: .awaitingWeight, spool: knownSpool(lastScaleWeight: 734)))
        #expect(weighed.suggestion(mode: .gross) == 734)
        #expect(weighed.suggestion(mode: .net) == 484)
        let never = FeedItem(try row(status: .awaitingWeight, spool: knownSpool(lastScaleWeight: nil, weightUsed: 100)))
        #expect(never.suggestion(mode: .gross) == 1150)
        #expect(never.suggestion(mode: .net) == 900)
        #expect(FeedItem(try row(status: .unknown(prefill: true))).suggestion(mode: .gross) == nil)
    }

    @Test func anUnknownTagShowsTheResolvedColourName() throws {
        var named = try row(status: .unknown(prefill: true))
        named.colorName = "Jade White"
        #expect(FeedItem(named).colorName == "Jade White")
        // a known spool shows Bambuddy's own name
        named.spool = knownSpool(colorName: "Bambuddy White")
        #expect(FeedItem(named).colorName == "Bambuddy White")
    }

    @Test func anUnknownTagShowsTheTagData() throws {
        let item = FeedItem(try row(status: .unknown(prefill: true)))
        let tag = try row().tag
        #expect(item.title == tag.detailedType)
        // the hex is never a colour name; the swatch shows the colour
        #expect(item.colorName == nil)
        #expect(item.remainingText == "label \(tag.labelWeight ?? 0) g")
        #expect(!item.canWeigh)
        #expect(item.offersUnknownActions)
        #expect(item.hasPrefill)
    }

    @Test func anNTAGWithoutMaterialIsTitledByItsType() throws {
        let item = FeedItem(try row("scan_ntag", status: .unknown(prefill: false)))
        #expect(item.title == "NTAG 7-byte UID 0411\u{2026}")
        #expect(item.colorName == nil)
        #expect(item.swatch == nil)
        #expect(item.offersUnknownActions)
        #expect(!item.hasPrefill)
    }

    @Test func titlesJoinMaterialAndSubtype() {
        #expect(FeedItem.title(material: "PLA", subtype: "PLA Basic") == "PLA Basic")
        #expect(FeedItem.title(material: "PETG", subtype: "HF") == "PETG HF")
        #expect(FeedItem.title(material: "ABS", subtype: nil) == "ABS")
        #expect(FeedItem.title(material: "PLA", subtype: "pla matte") == "pla matte")
    }

    @Test func aRowStillLookingUpOffersNoActions() throws {
        let item = FeedItem(try row(status: .scanned))
        #expect(!item.canWeigh)
        #expect(!item.offersUnknownActions)
    }

    @Test func swatchesParseEightHexDigits() throws {
        let swatch = try #require(Swatch(rgba: "FF800040"))
        #expect(swatch.red == 1)
        #expect(abs(swatch.green - 128.0 / 255) < 1e-9)
        #expect(swatch.blue == 0)
        #expect(abs(swatch.alpha - 64.0 / 255) < 1e-9)
        #expect(Swatch(rgba: "#FF800040") == swatch)
        #expect(Swatch(rgba: "FFF") == nil)
        #expect(Swatch(rgba: "GG000000") == nil)
    }

    @Test func clearEmptiesTheFeed() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        model.apply(await session.snapshot)
        model.setWeightText("12", for: id)

        await model.clear()

        #expect(model.items.isEmpty)
        #expect(await session.rows.isEmpty)
        #expect(model.weightText(for: id) == "")
    }
}

@MainActor
@Suite("FeedViewModel: unknown rows")
struct FeedViewModelUnknownTests {
    private func spools() -> [Spool] {
        [
            Spool(id: 1, material: "PLA", subtype: "PLA Matte", colorName: "Charcoal", brand: "Bambu Lab",
                  labelWeight: 1000, coreWeight: 250, weightUsed: 0),
            Spool(id: 2, material: "PETG", colorName: "Translucent Teal", brand: "Polymaker",
                  labelWeight: 1000, coreWeight: 200, weightUsed: 0, note: "shelf B"),
            Spool(id: 3, material: "TPU", brand: "eSUN", labelWeight: 500, coreWeight: 150, weightUsed: 0,
                  note: "for gaskets"),
        ]
    }

    @Test func theLinkFilterMatchesMaterialColourBrandAndNoteCaseInsensitively() {
        let all = spools()
        #expect(FeedViewModel.filter(all, query: "").map(\.id) == [1, 2, 3])
        #expect(FeedViewModel.filter(all, query: "  ").map(\.id) == [1, 2, 3])
        #expect(FeedViewModel.filter(all, query: "petg").map(\.id) == [2])
        #expect(FeedViewModel.filter(all, query: "CHARCOAL").map(\.id) == [1])
        #expect(FeedViewModel.filter(all, query: "polymaker").map(\.id) == [2])
        #expect(FeedViewModel.filter(all, query: "Gaskets").map(\.id) == [3])
        #expect(FeedViewModel.filter(all, query: "matte").map(\.id) == [1])
        #expect(FeedViewModel.filter(all, query: "teal shelf").map(\.id) == [2])
        #expect(FeedViewModel.filter(all, query: "teal gaskets").isEmpty)
        #expect(FeedViewModel.filter(all, query: "nylon").isEmpty)
    }

    @Test func linkCandidatesLoadFromBambuddy() async throws {
        let inventory = FakeInventory(spools: spools())
        let (model, _) = makeModel(inventory)

        await model.loadLinkCandidates()

        #expect(model.linkCandidates.map(\.id) == [1, 2, 3])
        #expect(model.linkMatches("tpu").map(\.id) == [3])
        #expect(model.linkError == nil)
    }

    @Test func linkCandidatesNeedAUsableBambuddy() async throws {
        let inventory = FakeInventory(spools: spools())
        inventory.spoolman = true
        let (model, _) = makeModel(inventory)

        await model.loadLinkCandidates()

        #expect(model.linkCandidates.isEmpty)
        #expect(model.linkError == BambuddyState.refused(.spoolmanMode).message)
    }

    @Test func linkingAttachesTheTagToTheChosenSpool() async throws {
        let inventory = FakeInventory(spools: spools())
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(await model.link(id, toSpool: 2))

        #expect(model.items.first?.spoolId == 2)
        #expect(model.items.first?.canWeigh == true)
    }

    @Test func aTagLinkedElsewhereShowsTheConflict() async throws {
        let inventory = FakeInventory(spools: spools())
        inventory.linkError = .tagAlreadyLinked(otherSpoolId: nil)
        let (model, session) = makeModel(inventory)
        let id = await session.record(try fixtureScan("scan_ntag"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        #expect(!(await model.link(id, toSpool: 2)))

        let message = try #require(model.error(for: id))
        #expect(message == BambuddyError.tagAlreadyLinked(otherSpoolId: nil).localizedDescription)
        // The row stays open for another try.
        #expect(model.items.first?.offersUnknownActions == true)
    }

    @Test func theNewFormIsPrefilledFromTheTagAndSettings() async throws {
        let (model, session) = makeModel(FakeInventory())
        let id = await session.record(try scan("s-1"))
        model.apply(await session.snapshot)
        let tag = try row().tag

        let form = try #require(model.newSpoolForm(for: id))

        #expect(form.material == tag.material)
        #expect(form.subtype == "Basic")
        #expect(form.colorName == "")
        #expect(form.brand == "Bambu Lab")
        #expect(form.labelWeight == String(tag.labelWeight ?? 1000))
        #expect(form.newSpool == NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
    }

    @Test func theNewFormCarriesTheResolvedColourName() async throws {
        let inventory = FakeInventory()
        inventory.colorMapAnswer = sampleColorMap
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        let form = try #require(model.newSpoolForm(for: id))

        #expect(form.colorName == "Jade White")
        #expect(form.newSpool?.colorName == "Jade White")
        #expect(model.items.first?.colorName == "Jade White")
    }

    @Test func aFailedColourMapIsShownInTheStatus() async throws {
        let inventory = FakeInventory()
        inventory.colorMapError = .network("timed out")
        let (model, session) = makeModel(inventory)
        _ = await session.checkBambuddy()

        model.apply(await session.snapshot)

        #expect(model.colorNamesProblem == "Colour names unavailable: \(BambuddyError.network("timed out").localizedDescription)")
    }

    @Test func aFormWithoutMaterialCannotBeSubmitted() async throws {
        let (model, session) = makeModel(FakeInventory())
        var ntag = try fixtureScan("scan_ntag")
        ntag.scanId = "s-9"
        let id = await session.record(ntag)
        model.apply(await session.snapshot)

        var form = try #require(model.newSpoolForm(for: id))
        #expect(form.material == "")
        #expect(form.labelWeight == "1000")
        #expect(form.newSpool == nil)

        form.material = "  "
        #expect(form.newSpool == nil)
        form.material = " PLA "
        let spool = try #require(form.newSpool)
        #expect(spool.material == "PLA")
        #expect(spool.subtype == nil)
        #expect(spool.colorName == nil)
        #expect(spool.brand == nil)
        #expect(spool.tagType == "ntag")
        #expect(spool.coreWeight == 250)

        form.labelWeight = "0"
        #expect(form.newSpool == nil)
        form.labelWeight = "12x"
        #expect(form.newSpool == nil)
    }

    @Test func creatingFromTheFormLinksTheRow() async throws {
        let inventory = FakeInventory()
        let (model, session) = makeModel(inventory)
        let id = await session.record(try fixtureScan("scan_ntag"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        var form = try #require(model.newSpoolForm(for: id))
        form.material = "PLA"
        form.colorName = "Jade White"
        #expect(await model.create(id, form))

        guard case .create(let sent) = try #require(inventory.creates.first) else { return }
        #expect(sent.colorName == "Jade White")
        let item = try #require(model.items.first)
        #expect(item.statusText == "Created in Bambuddy")
        #expect(item.savedByText == "by host")
        #expect(item.canWeigh)
    }

    @Test func noRowNoForm() {
        let (model, _) = makeModel()
        #expect(model.newSpoolForm(for: UUID()) == nil)
    }

    // MARK: Focus

    /// A known-spool row in `status`, as the session would hold it.
    private func spoolRow(_ scanId: String, _ status: FeedRow.Status) throws -> FeedRow {
        var row = FeedRow(scanId: scanId, dump: try fixtureScan().tag, spool: knownSpool(), status: status)
        row.status = status
        return row
    }

    private func snapshot(_ rows: [FeedRow]) -> SessionSnapshot {
        SessionSnapshot(rows: rows, bambuddy: .unchecked)
    }

    @Test func onlyEnterWeightAndCreatedRowsWait() throws {
        #expect(FeedItem(try spoolRow("s", .awaitingWeight)).isWaiting)
        #expect(FeedItem(try spoolRow("s", .created)).isWaiting)
        for status: FeedRow.Status in [.scanned, .saving, .saved, .savedAfterTimeout, .error("x"), .unknown(prefill: true)] {
            #expect(!FeedItem(try spoolRow("s", status)).isWaiting)
        }
        #expect(!FeedItem(try row(status: .awaitingWeight)).isWaiting)
    }

    @Test func theNewestWaitingRowTakesFocus() throws {
        let (model, _) = makeModel()
        let older = try spoolRow("s-1", .awaitingWeight)
        let newer = try spoolRow("s-2", .awaitingWeight)

        model.apply(snapshot([older, newer]))

        #expect(model.focusedRow == newer.id)
    }

    @Test func aRefreshWithoutAStateChangeDoesNotMoveFocus() throws {
        let (model, _) = makeModel()
        let older = try spoolRow("s-1", .awaitingWeight)
        let newer = try spoolRow("s-2", .awaitingWeight)
        model.apply(snapshot([older, newer]))

        model.focusedRow = older.id
        model.apply(snapshot([older, newer]))

        #expect(model.focusedRow == older.id)
    }

    @Test func aScanWhileTypingOnlyHintsTheNewRow() throws {
        let (model, _) = makeModel()
        let typing = try spoolRow("s-1", .awaitingWeight)
        model.apply(snapshot([typing]))
        model.setWeightText("9", for: typing.id)

        let scanned = try spoolRow("s-2", .awaitingWeight)
        model.apply(snapshot([typing, scanned]))

        #expect(model.focusedRow == typing.id)
        #expect(model.focus.hintedRow == scanned.id)
    }

    @Test func aSavedRowPassesFocusToTheNextWaitingRow() throws {
        let (model, _) = makeModel()
        var first = try spoolRow("s-1", .awaitingWeight)
        let second = try spoolRow("s-2", .awaitingWeight)
        model.apply(snapshot([first, second]))
        model.focusedRow = first.id

        first.status = .saving
        model.apply(snapshot([first, second]))
        #expect(model.focusedRow == first.id)
        first.status = .saved
        model.apply(snapshot([first, second]))

        #expect(model.focusedRow == second.id)
    }

    @Test func aReopenedRowTakesFocus() throws {
        let (model, _) = makeModel()
        var row = try spoolRow("s-1", .saved)
        model.apply(snapshot([row]))
        #expect(model.focusedRow == nil)

        row.status = .awaitingWeight
        model.apply(snapshot([row]))

        #expect(model.focusedRow == row.id)
    }

    @Test func writingBackTheUntouchedSuggestionDoesNotTouchTheRow() throws {
        let (model, _) = makeModel()
        let row = try spoolRow("s-1", .awaitingWeight)
        model.apply(snapshot([row]))
        let suggestion = model.weightText(for: row.id)

        // a text field echoing its value on focus loss
        model.setWeightText(suggestion, for: row.id)
        #expect(!model.draft(for: row.id).touched)
        let scanned = try spoolRow("s-2", .awaitingWeight)
        model.apply(snapshot([row, scanned]))
        #expect(model.focusedRow == scanned.id)

        model.setWeightText(suggestion + "1", for: scanned.id)
        #expect(model.draft(for: scanned.id).touched)
    }

    @Test func commandSSavesTheFocusedRow() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, session) = makeModel(inventory)
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)
        #expect(model.focusedRow == id)

        model.setWeightText("734", for: id)
        await model.saveFocused()

        #expect(inventory.updates == [.update(spoolId: 42, gross: 734)])
        #expect(model.focusedRow == id)
    }

    @Test func commandSWithoutFocusDoesNothing() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let (model, _) = makeModel(inventory)

        await model.saveFocused()

        #expect(inventory.updates.isEmpty)
    }

    @Test func commandUpAndDownMoveThroughTheFeed() throws {
        let (model, _) = makeModel()
        let older = try spoolRow("s-1", .saved)
        let newer = try spoolRow("s-2", .awaitingWeight)
        model.apply(snapshot([older, newer]))

        model.moveFocus(.down)
        #expect(model.focusedRow == older.id)
        model.moveFocus(.up)
        #expect(model.focusedRow == newer.id)
    }

    @Test func clearDropsTheFocus() async throws {
        let (model, session) = makeModel()
        let id = await session.record(try scan("s-1"))
        _ = await session.lookup(row: id)
        model.apply(await session.snapshot)

        await model.clear()

        #expect(model.focusedRow == nil)
    }
}
