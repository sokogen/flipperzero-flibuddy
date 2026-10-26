import Foundation
import Testing
@testable import SpoolBuddyCore

/// The spool `lookup_found.json` describes, carrying the synthetic fixture's UID in
/// the AMS form.
func knownSpool(
    lastScaleWeight: Int? = 734, weightUsed: Double = 516, colorName: String? = "Jade White", subtype: String? = "PLA Basic"
) -> Spool {
    Spool(
        id: 42, material: "PLA", subtype: subtype, colorName: colorName, rgba: "FFFFFFFF",
        brand: "Bambu Lab", labelWeight: 1000, coreWeight: 250, coreWeightCatalogId: 3,
        weightUsed: weightUsed, lastScaleWeight: lastScaleWeight, tagUid: "5A3C9E2100000100", tagType: "bambulab"
    )
}

let testSettings = Settings(
    baseURL: "http://bambuddy.test:8000", apiKey: "bb_test", catalogEntryId: 3, coreWeight: 250, defaultMode: .gross
)

func fixtureMessage(_ name: String) throws -> Message {
    try Message.decode(line: Fixtures.message(name))
}

func fixtureScan(_ name: String = "scan_mfc") throws -> Scan {
    guard case .scan(let scan) = try fixtureMessage(name) else { fatalError("\(name) is not a scan") }
    return scan
}

func fixtureIntent(_ name: String) throws -> Intent {
    guard case .intent(let intent) = try fixtureMessage(name) else { fatalError("\(name) is not an intent") }
    return intent
}

func fixtureLookup(_ name: String) throws -> Lookup {
    guard case .lookup(let lookup) = try fixtureMessage(name) else { fatalError("\(name) is not a lookup") }
    return lookup
}

func fixtureResult(_ name: String) throws -> IntentResult {
    guard case .result(let result) = try fixtureMessage(name) else { fatalError("\(name) is not a result") }
    return result
}

/// A weigh intent for the scan in `scan_mfc.json`.
func weighIntent(id: String = "i-000003", grams: Int, mode: Intent.WeightMode, scanId: String = "s-000012") throws -> Intent {
    var intent = try fixtureIntent("intent_weigh")
    intent.id = id
    intent.grams = grams
    intent.mode = mode
    intent.scanId = scanId
    return intent
}

private func makeSession(_ inventory: FakeInventory?, settings: Settings = testSettings) -> Session {
    Session(settings: settings, inventory: inventory)
}

@Suite("Session: scans and lookups")
struct SessionScanTests {
    @Test func aScanCreatesAScannedRow() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        let scan = try fixtureScan()

        let rowID = await session.record(scan)

        let rows = await session.rows
        #expect(rows.count == 1)
        #expect(rows[0].id == rowID)
        #expect(rows[0].status == .scanned)
        #expect(rows[0].scanId == "s-000012")
        #expect(rows[0].tag == TagParser.parse(scan.tag))
        #expect(rows[0].spool == nil)
        #expect(rows[0].savedBy == nil)
    }

    @Test func aFoundLookupCarriesTheSpoolAndAwaitsWeight() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try fixtureScan())

        #expect(lookup == (try fixtureLookup("lookup_found")))
        let row = try #require(await session.rows.first)
        #expect(row.spool == knownSpool())
        #expect(row.status == .awaitingWeight)
        let tag = row.tag
        #expect(inventory.calls == [.spoolman, .find(tray: tag.trayUuid, uid: "5A3C9E2100000100")])
    }

    @Test func theFoundReplyEncodesForTheFlipper() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        let reply = try #require(await session.handle(.scan(try fixtureScan())))
        let line = try reply.encodedLine()
        #expect(try Message.decode(line: line) == (try fixtureMessage("lookup_found")))
    }

    @Test func foundDefaultsWithoutAScaleWeightUseRemainingPlusCore() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool(lastScaleWeight: nil, weightUsed: 0)]))
        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.defaults == Lookup.Defaults(gross: 1250, label: 1000, core: 250))
        #expect(lookup.lines[2] == "1000 g left of 1000")
    }

    @Test func foundLinesFallBackToTheRGBAAndStayWithinFlipperLimits() async throws {
        let long = String(repeating: "Jade White ", count: 6)
        let session = makeSession(FakeInventory(spools: [knownSpool(colorName: long)]))
        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.lines.count <= 4)
        #expect(lookup.lines.allSatisfy { $0.unicodeScalars.count <= 40 })
        #expect(lookup.lines[1] == String(long.prefix(40)))

        let plain = makeSession(FakeInventory(spools: [knownSpool(colorName: nil)]))
        #expect(await plain.handleScan(try fixtureScan()).lines[1] == "#FFFFFFFF")
    }

    @Test func foundLinesShowTheFullTypeForASubtypeWithoutTheMaterial() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool(subtype: "Basic")]))
        #expect(await session.handleScan(try fixtureScan()).lines[0] == "PLA Basic")

        let bare = makeSession(FakeInventory(spools: [knownSpool(subtype: nil)]))
        #expect(await bare.handleScan(try fixtureScan()).lines[0] == "PLA")
    }

    @Test func anUnknownTagWithMaterialOffersPrefill() async throws {
        let session = makeSession(FakeInventory())

        let lookup = await session.handleScan(try fixtureScan())

        #expect(lookup == (try fixtureLookup("lookup_unknown")))
        #expect(await session.rows.first?.status == .unknown(prefill: true))
    }

    @Test func unknownDefaultsUseTheConfiguredCoreWeight() async throws {
        var settings = testSettings
        settings.coreWeight = 180
        let session = makeSession(FakeInventory(), settings: settings)
        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.defaults == Lookup.Defaults(label: 1000, core: 180))
    }

    @Test func anUnknownNTAGHasNoPrefill() async throws {
        let session = makeSession(FakeInventory())

        let lookup = await session.handleScan(try fixtureScan("scan_ntag"))

        #expect(lookup.status == .unknown)
        #expect(lookup.prefill == nil)
        #expect(lookup.spoolId == nil)
        #expect(await session.rows.first?.status == .unknown(prefill: false))
    }

    @Test func anUnreadableMfcIsLookedUpByUIDWithoutPrefill() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try fixtureScan("scan_mfc_unreadable"))

        #expect(lookup.scanId == "s-000014")
        #expect(lookup.status == .unknown)
        #expect(lookup.prefill == nil)
        #expect(inventory.calls.contains(.find(tray: nil, uid: "5A3C9E2100000100")))
    }

    @Test func aFailedLookupAnswersErrorAndMarksTheRow() async throws {
        let inventory = FakeInventory()
        inventory.findError = .network("connection timed out")
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try fixtureScan())

        #expect(lookup.status == .error)
        #expect(lookup.lines == ["Bambuddy unreachable"])
        #expect(lookup.error == "Bambuddy unreachable: connection timed out")
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: connection timed out"))
    }

    @Test func otherLookupFailuresSayLookupFailed() async throws {
        let inventory = FakeInventory()
        inventory.findError = .http(status: 500, message: "boom")
        let lookup = await makeSession(inventory).handleScan(try fixtureScan())
        #expect(lookup.lines == ["Lookup failed"])
        #expect(lookup.error == "Bambuddy HTTP 500: boom")
    }

    @Test func aLookupForAClearedRowSaysTheScanWasDropped() async throws {
        let session = makeSession(FakeInventory())
        let lookup = await session.lookup(row: UUID())
        #expect(lookup.status == .error)
        #expect(lookup.lines == ["Scan dropped"])
        #expect(lookup.error == "row cleared")
    }

    @Test func handleDispatchesByMessageType() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        #expect(await session.handle(.hello(Hello(app: "spoolbuddy", fw: "1.5.1"))) == nil)
        #expect(await session.handle(.lookup(try fixtureLookup("lookup_found"))) == nil)
        guard case .lookup = await session.handle(.scan(try fixtureScan())) else {
            Issue.record("scan must answer lookup")
            return
        }
        guard case .result(let result) = await session.handle(.intent(try weighIntent(grams: 734, mode: .gross))) else {
            Issue.record("intent must answer result")
            return
        }
        #expect(result.ok)
    }

    @Test func clearEmptiesTheFeed() async throws {
        let session = makeSession(FakeInventory())
        _ = await session.record(try fixtureScan())
        _ = await session.record(try fixtureScan("scan_ntag"))
        #expect(await session.rows.count == 2)
        await session.clear()
        #expect(await session.rows.isEmpty)
    }

    @Test func snapshotsFollowTheFeed() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        let snapshots = await Collector.draining(await session.snapshots())
        #expect(await eventually { await snapshots.items.count == 1 })
        #expect(await snapshots.items.first == SessionSnapshot(rows: [], bambuddy: .unchecked))

        _ = await session.handleScan(try fixtureScan())

        #expect(await eventually { await snapshots.items.last?.rows.first?.status == .awaitingWeight })
        #expect(await snapshots.items.last?.bambuddy == .ready)
        #expect(await snapshots.items.contains { $0.rows.first?.status == .scanned })
    }
}

@Suite("Session: startup check")
struct SessionStartupTests {
    @Test func internalModeIsReady() async throws {
        let session = makeSession(FakeInventory())
        #expect(await session.bambuddy == .unchecked)
        #expect(await session.checkBambuddy() == .ready)
    }

    @Test func spoolmanModeIsRefusedWithAClearMessage() async throws {
        let inventory = FakeInventory()
        inventory.spoolman = true
        let session = makeSession(inventory)

        let state = await session.checkBambuddy()

        #expect(state == .refused(.spoolmanMode))
        #expect(state.message?.contains("Spoolman mode") == true)
        #expect(state.message?.contains("internal inventory") == true)
    }

    @Test func aRefusedSessionAnswersScansWithoutTouchingTheInventory() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.spoolman = true
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try fixtureScan())
        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(lookup.status == .error)
        #expect(lookup.lines == ["Spoolman mode", "not supported"])
        #expect(lookup.error == BambuddyState.refused(.spoolmanMode).message)
        #expect(!result.ok)
        #expect(result.lines == ["Not saved", "Spoolman mode", "not supported"])
        #expect(inventory.calls == [.spoolman])
        #expect(await session.rows.first?.status == .error(BambuddyState.refused(.spoolmanMode).message!))
    }

    @Test func aMissingPermissionIsNamed() async throws {
        let inventory = FakeInventory()
        inventory.spoolmanError = .permissionMissing("settings:read")
        let session = makeSession(inventory)

        let state = await session.checkBambuddy()

        #expect(state == .refused(.permissionMissing("settings:read")))
        #expect(state.message?.contains("settings:read") == true)
        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.lines == ["API key lacks", "settings:read"])
    }

    @Test func aRejectedKeyIsRefused() async throws {
        let inventory = FakeInventory()
        inventory.spoolmanError = .unauthorized
        #expect(await makeSession(inventory).checkBambuddy() == .refused(.unauthorized))
    }

    @Test func anUnreachableBambuddyIsCheckedAgainOnTheNextScan() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.spoolmanError = .network("connection refused")
        let session = makeSession(inventory)

        let first = await session.handleScan(try fixtureScan())
        #expect(first.status == .error)
        #expect(first.lines == ["Bambuddy unreachable"])
        #expect(await session.bambuddy == .unreachable("Bambuddy unreachable: connection refused"))

        inventory.spoolmanError = nil
        let second = await session.handleScan(try fixtureScan())
        #expect(second.status == .found)
        #expect(await session.bambuddy == .ready)
    }

    @Test func refusalSticksUntilCheckedAgain() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.spoolman = true
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.spoolman = false
        #expect(await session.handleScan(try fixtureScan()).status == .error)
        #expect(await session.checkBambuddy() == .ready)
        #expect(await session.handleScan(try fixtureScan()).status == .found)
    }

    @Test func withoutBambuddySettingsTheSessionSaysSo() async throws {
        let session = makeSession(nil, settings: Settings())
        #expect(await session.checkBambuddy() == .notConfigured)
        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.status == .error)
        #expect(lookup.lines == ["Bambuddy not set up", "see host settings"])
    }

    @Test func reconfiguringResetsTheCheck() async throws {
        let session = makeSession(nil, settings: Settings())
        _ = await session.checkBambuddy()
        await session.reconfigure(settings: testSettings, inventory: FakeInventory())
        #expect(await session.bambuddy == .unchecked)
        #expect(await session.checkBambuddy() == .ready)
    }

    @Test func aCheckOfOldSettingsDoesNotOverwriteTheNewOnes() async throws {
        let old = FakeInventory()
        old.spoolman = true
        old.spoolmanDelay = .milliseconds(200)
        let session = makeSession(old)
        let stale = Task { await session.checkBambuddy() }
        try await Task.sleep(for: .milliseconds(50))

        await session.reconfigure(settings: testSettings, inventory: FakeInventory())
        #expect(await session.checkBambuddy() == .ready)

        #expect(await stale.value == .ready)
        #expect(await session.bambuddy == .ready)
    }
}

@Suite("Session: colour names")
struct SessionColorNameTests {
    private func namingInventory(spools: [Spool] = []) -> FakeInventory {
        let inventory = FakeInventory(spools: spools)
        inventory.colorMapAnswer = sampleColorMap
        return inventory
    }

    @Test func theMapIsLoadedOnceAfterTheStartupCheck() async throws {
        let inventory = namingInventory()
        let session = makeSession(inventory)
        #expect(await session.checkBambuddy() == .ready)
        #expect(inventory.colorMapLoads == 1)
        _ = await session.handleScan(try fixtureScan())
        _ = await session.handleScan(try fixtureScan("scan_ntag"))
        #expect(inventory.colorMapLoads == 1)
    }

    @Test func aRefusedBambuddyLoadsNoMap() async throws {
        let inventory = namingInventory()
        inventory.spoolman = true
        let session = makeSession(inventory)
        _ = await session.checkBambuddy()
        #expect(inventory.colorMapLoads == 0)
    }

    @Test func scannedRowsCarryTheResolvedName() async throws {
        let session = makeSession(namingInventory())
        _ = await session.handleScan(try fixtureScan())
        let row = try #require(await session.rows.first)
        #expect(row.colorName == "Jade White")
        #expect(FeedItem(row).colorName == "Jade White")
    }

    @Test func rowsRecordedBeforeTheMapArrivesAreNamedWhenItDoes() async throws {
        let session = makeSession(namingInventory())
        _ = await session.record(try fixtureScan())
        #expect(await session.rows.first?.colorName == nil)
        _ = await session.checkBambuddy()
        #expect(await session.rows.first?.colorName == "Jade White")
    }

    @Test func aColourWithoutANameStaysUnnamed() async throws {
        let session = makeSession(namingInventory())
        _ = await session.checkBambuddy()
        _ = await session.record(Scan(scanId: "s-000020", tag: try TagFixtures.bambuReal()))
        let row = try #require(await session.rows.first)
        #expect(row.colorName == nil)
        #expect(FeedItem(row).colorName == "#A4DBE8FF")
    }

    @Test func aFlipperNewSendsTheResolvedName() async throws {
        let inventory = namingInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try fixtureIntent("intent_new")

        let result = await session.handleIntent(intent)

        #expect(result.ok)
        let expected = try #require(
            NewSpool(tag: TagParser.parse(intent.tag), coreWeight: 250, coreWeightCatalogId: 3, colorName: "Jade White")
        )
        #expect(inventory.creates == [.create(expected)])
    }

    @Test func aFlipperNewForAnUnnamedColourOmitsTheName() async throws {
        let inventory = namingInventory()
        let session = makeSession(inventory)
        var intent = try fixtureIntent("intent_new")
        intent.tag = try TagFixtures.bambuReal()

        let result = await session.handleIntent(intent)

        #expect(result.ok)
        guard case .create(let sent) = try #require(inventory.creates.first) else { return }
        #expect(sent.colorName == nil)
    }

    @Test func aFailedLoadIsReportedAndNeverBlocksAScanOrACreate() async throws {
        let inventory = namingInventory()
        inventory.colorMapError = .permissionMissing("inventory:read")
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.status == .unknown)
        #expect(await session.bambuddy == .ready)
        let problem = try #require(await session.snapshot.colorNamesProblem)
        #expect(problem.hasPrefix("Colour names unavailable"))
        #expect(problem.contains("inventory:read"))

        let result = await session.handleIntent(try fixtureIntent("intent_new"))
        #expect(result.ok)
        guard case .create(let sent) = try #require(inventory.creates.first) else { return }
        #expect(sent.colorName == nil)
        #expect(await session.rows.first?.colorName == nil)
    }

    @Test func aFailedLoadIsRetriedByTheNextCheck() async throws {
        let inventory = namingInventory()
        inventory.colorMapError = .network("timed out")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        #expect(await session.snapshot.colorNamesProblem != nil)

        inventory.colorMapError = nil
        _ = await session.checkBambuddy()

        #expect(inventory.colorMapLoads == 2)
        #expect(await session.snapshot.colorNamesProblem == nil)
        #expect(await session.rows.first?.colorName == "Jade White")
    }

    @Test func newSettingsLoadTheMapAgain() async throws {
        let inventory = namingInventory()
        let session = makeSession(inventory)
        _ = await session.checkBambuddy()
        let other = namingInventory()
        other.colorMapAnswer = ColorMap(colors: ["ffffff": "Snow"], byMaterial: [:])
        await session.reconfigure(settings: testSettings, inventory: other)
        _ = await session.handleScan(try fixtureScan())

        #expect(other.colorMapLoads == 1)
        #expect(await session.rows.first?.colorName == "Snow")
    }
}

@Suite("Session: intents")
struct SessionIntentTests {
    @Test func weighNetSendsNetPlusCore() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 484, mode: .net))

        #expect(inventory.updates == [.update(spoolId: 42, gross: 734)])
        #expect(result == (try fixtureResult("result_ok")))
        let row = try #require(await session.rows.first)
        #expect(row.status == .saved)
        #expect(row.savedBy == .flipper)
        #expect(row.weight == FeedRow.Weight(grams: 484, mode: .net))
        #expect(row.spool?.lastScaleWeight == 734)
        #expect(row.spool?.remaining == 484)
    }

    @Test func weighNetWithAZeroCoreSendsTheNet() async throws {
        var spool = knownSpool()
        spool.coreWeight = 0
        let inventory = FakeInventory(spools: [spool])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 484, mode: .net))

        #expect(inventory.updates == [.update(spoolId: 42, gross: 484)])
        #expect(result.ok)
        #expect(try #require(await session.rows.first).spool?.remaining == 484)
    }

    @Test func weighGrossSendsTheGramsAsTheyAre() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 650, mode: .gross))

        #expect(inventory.updates == [.update(spoolId: 42, gross: 650)])
        #expect(result.lines == ["Saved", "400 g left"])
    }

    @Test func weighWithoutAPriorScanLooksTheSpoolUpAndAddsARow() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(inventory.updates == [.update(spoolId: 42, gross: 734)])
        let rows = await session.rows
        #expect(rows.count == 1)
        #expect(rows[0].scanId == "s-000012")
        #expect(rows[0].status == .saved)
    }

    @Test func weighForAnUnknownSpoolFailsWithoutAnUpdate() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(!result.ok)
        #expect(result.lines == ["Not saved", "Spool not found"])
        #expect(result.error == "no spool for tag 5A3C9E21")
        #expect(inventory.updates.isEmpty)
    }

    @Test func newCreatesWithTheConfiguredCatalogEntryAndLinksTheRow() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try fixtureIntent("intent_new")

        let result = await session.handleIntent(intent)

        let tag = TagParser.parse(intent.tag)
        let expected = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(inventory.creates == [.create(expected)])
        #expect(expected.tagUid == "5A3C9E2100000100")
        #expect(expected.subtype == "Basic")
        #expect(result == IntentResult(id: "i-000004", ok: true, lines: ["Created", "spool #100"]))
        let row = try #require(await session.rows.first)
        #expect(row.spool?.id == 100)
        // Only Bambuddy's subtype drops the material word; the feed reads in full.
        #expect(FeedItem(row).title == "PLA Basic")
        #expect(row.status == .created)
        #expect(row.savedBy == .flipper)
    }

    @Test func newRefusesATagThatAlreadyMatches() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)

        let result = await session.handleIntent(try fixtureIntent("intent_new"))

        #expect(!result.ok)
        #expect(result.lines == ["Already in Bambuddy", "spool #42"])
        #expect(inventory.creates.isEmpty)
        #expect(await session.rows.first?.spool?.id == 42)
    }

    @Test func aFailedCreateIsReportedAndRetriedOnARepeatedId() async throws {
        let inventory = FakeInventory()
        inventory.createError = .network("timed out")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try fixtureIntent("intent_new")

        let first = await session.handleIntent(intent)
        #expect(!first.ok)
        #expect(first.lines == ["Not created"])
        #expect(first.error == "Bambuddy unreachable: timed out")
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))
        #expect(await session.rows.first?.spool == nil)

        inventory.createError = nil
        let second = await session.handleIntent(intent)
        #expect(second == IntentResult(id: intent.id, ok: true, lines: ["Created", "spool #100"]))
        #expect(inventory.creates.count == 2)
    }

    @Test func aFailedLookupBeforeNewCreatesNothing() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.findError = .http(status: 500, message: "boom")

        let result = await session.handleIntent(try fixtureIntent("intent_new"))

        #expect(!result.ok)
        #expect(result.lines == ["Not created"])
        #expect(inventory.creates.isEmpty)
    }

    @Test func newRefusesATagWithoutMaterial() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        var intent = try fixtureIntent("intent_new")
        intent.tag = try TagFixtures.bambu(missing: [0])

        let result = await session.handleIntent(intent)

        #expect(!result.ok)
        #expect(result.lines == ["Not created", "No material on tag"])
        #expect(inventory.creates.isEmpty)
    }

    @Test(arguments: [
        ("intent_create_on_host", FeedRow.HostRequest.create),
        ("intent_link_on_host", FeedRow.HostRequest.link),
    ])
    func onHostIntentsOnlyFlagTheRow(name: String, request: FeedRow.HostRequest) async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let lookup = await session.handleScan(try fixtureScan("scan_ntag"))
        #expect(lookup.status == .unknown)
        let callsAfterScan = inventory.calls

        let intent = try fixtureIntent(name)
        let result = await session.handleIntent(intent)

        #expect(result == IntentResult(id: intent.id, ok: true, lines: ["Flagged on host"]))
        #expect(inventory.calls == callsAfterScan)
        let rows = await session.rows
        #expect(rows.count == 1)
        #expect(rows[0].request == request)
        #expect(rows[0].status == .unknown(prefill: false))
    }

    @Test func onHostIntentsWorkWithoutBambuddy() async throws {
        let session = makeSession(nil, settings: Settings())
        let result = await session.handleIntent(try fixtureIntent("intent_link_on_host"))
        #expect(result.ok)
        #expect(await session.rows.first?.request == .link)
    }

    @Test func aRepeatedIntentIdReturnsTheCachedResult() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try weighIntent(grams: 484, mode: .net)

        let first = await session.handleIntent(intent)
        let second = await session.handleIntent(intent)

        #expect(first == second)
        #expect(inventory.updates.count == 1)
    }

    @Test func aReusedIdWithAnotherPayloadIsPerformedAgain() async throws {
        // A restarted Flipper may reuse an id the host still remembers.
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        _ = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))
        let second = await session.handleIntent(try weighIntent(grams: 500, mode: .gross))

        #expect(second.ok)
        #expect(inventory.updates == [.update(spoolId: 42, gross: 734), .update(spoolId: 42, gross: 500)])
        // The newer intent is the one remembered.
        _ = await session.handleIntent(try weighIntent(grams: 500, mode: .gross))
        #expect(inventory.updates.count == 2)
    }

    @Test func aReusedIdWaitsForTheIntentStillRunningUnderIt() async throws {
        // A Flipper that restarts mid-intent may reuse its id while the host
        // still performs the old one: the newer intent goes second and stays.
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateDelays = [734: .milliseconds(200)]
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let older = try weighIntent(grams: 734, mode: .gross)
        let newer = try weighIntent(grams: 500, mode: .gross)

        async let pending = session.handleIntent(older)
        #expect(await eventually { inventory.updates.count == 1 })
        let result = await session.handleIntent(newer)
        _ = await pending

        #expect(result.ok)
        #expect(inventory.spools.first?.lastScaleWeight == 500)
        #expect(await session.rows.first?.spool?.lastScaleWeight == 500)
        #expect(await session.handleIntent(newer) == result)
        #expect(inventory.updates == [.update(spoolId: 42, gross: 734), .update(spoolId: 42, gross: 500)])
    }

    @Test func definitiveFailuresAreCachedToo() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let intent = try weighIntent(grams: 734, mode: .gross)

        _ = await session.handleIntent(intent)
        let findsAfterFirst = inventory.calls.count
        let second = await session.handleIntent(intent)

        #expect(!second.ok)
        #expect(inventory.calls.count == findsAfterFirst)
    }

    @Test func transientFailuresAreRetriedOnARepeatedId() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateError = .network("timed out")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try weighIntent(grams: 734, mode: .gross)

        let first = await session.handleIntent(intent)
        #expect(!first.ok)
        #expect(first.lines == ["Not saved"])
        #expect(first.error == "Bambuddy unreachable: timed out")
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))

        inventory.updateError = nil
        let second = await session.handleIntent(intent)
        #expect(second.ok)
        #expect(inventory.updates.count == 2)
    }

    @Test func theResultCacheForgetsTheOldestIds() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let count = Session.resultCacheSize + 1
        for n in 0..<count {
            _ = await session.handleIntent(try weighIntent(id: "i-\(n)", grams: 734, mode: .gross))
        }
        #expect(inventory.updates.count == count)

        _ = await session.handleIntent(try weighIntent(id: "i-\(count - 1)", grams: 734, mode: .gross))
        #expect(inventory.updates.count == count)
        _ = await session.handleIntent(try weighIntent(id: "i-0", grams: 734, mode: .gross))
        #expect(inventory.updates.count == count + 1)
    }

    @Test func anIdReusedForAnotherIntentCountsAsTheNewest() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        for n in 0..<Session.resultCacheSize {
            _ = await session.handleIntent(try weighIntent(id: "i-\(n)", grams: 734, mode: .gross))
        }
        let reused = try weighIntent(id: "i-0", grams: 500, mode: .gross)
        _ = await session.handleIntent(reused)
        _ = await session.handleIntent(try weighIntent(id: "i-new", grams: 734, mode: .gross))
        let updates = inventory.updates.count

        _ = await session.handleIntent(reused)
        #expect(inventory.updates.count == updates)
        _ = await session.handleIntent(try weighIntent(id: "i-1", grams: 734, mode: .gross))
        #expect(inventory.updates.count == updates + 1)
    }

    @Test func aWeighWithoutWeightUsedInTheReplyComputesIt() async throws {
        let inventory = FakeInventory(spools: [knownSpool(lastScaleWeight: nil, weightUsed: 0)])
        inventory.omitWeightUsed = true
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result == (try fixtureResult("result_ok")))
        #expect(await session.rows.first?.spool?.weightUsed == 516)
    }

    @Test func clearingTheFeedWhileAnIntentWaitsDropsIt() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.spoolmanDelay = .milliseconds(100)
        let session = makeSession(inventory)
        let intent = try weighIntent(grams: 734, mode: .gross)

        async let pending = session.handleIntent(intent)
        #expect(await eventually { await !session.rows.isEmpty })
        await session.clear()
        let result = await pending

        #expect(result == IntentResult(id: intent.id, ok: false, lines: ["Not saved"], error: "feed cleared; scan again"))
        #expect(await session.rows.isEmpty)
        #expect(inventory.updates.isEmpty)
    }

    @Test func clearingTheFeedDuringASaveDoesNotBringTheRowBack() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateDelay = .milliseconds(100)
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try weighIntent(grams: 734, mode: .gross)

        async let pending = session.handleIntent(intent)
        #expect(await eventually { inventory.updates.count == 1 })
        await session.clear()
        let result = await pending

        #expect(result.ok)
        #expect(await session.rows.isEmpty)
    }

    @Test func concurrentRepeatsShareOneCall() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateDelay = .milliseconds(50)
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try weighIntent(grams: 734, mode: .gross)

        async let first = session.handleIntent(intent)
        async let second = session.handleIntent(intent)
        let results = await [first, second]

        #expect(results[0] == results[1])
        #expect(inventory.updates.count == 1)
    }

    @Test func resultsAreValidWireMessages() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateError = .http(status: 500, message: String(repeating: "x", count: 400))
        let session = makeSession(inventory)
        let reply = try #require(await session.handle(.intent(try weighIntent(grams: 734, mode: .gross))))
        let decoded = try Message.decode(line: try reply.encodedLine())
        guard case .result(let result) = decoded else {
            Issue.record("expected a result")
            return
        }
        #expect(result.error?.unicodeScalars.count == 200)
    }
}

/// The host's New form for an NTAG: the tag carries only the UID, the user fills in the rest.
private func ntagForm(_ tag: ParsedTag) -> NewSpool {
    NewSpool(
        material: "PETG", colorName: "Jade White", labelWeight: 1000, coreWeight: 250, coreWeightCatalogId: 3,
        tagUid: tag.uid, tagType: tag.kind.bambuddyTagType
    )
}

@Suite("Session: host actions")
struct SessionHostActionTests {
    @Test func savingAWeightOnTheHostSendsTheSameUpdate() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        _ = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))
        let rowID = try #require(await session.rows.first?.id)

        try await session.saveWeight(row: rowID, grams: 300, mode: .net)

        #expect(inventory.updates == [.update(spoolId: 42, gross: 734), .update(spoolId: 42, gross: 550)])
        let row = try #require(await session.rows.first)
        #expect(row.savedBy == .host)
        #expect(row.status == .saved)
        #expect(row.weight == FeedRow.Weight(grams: 300, mode: .net))
        #expect(row.spool?.remaining == 300)
    }

    @Test func savingOnTheHostForAnUnknownRowFails() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)

        await #expect(throws: SessionError.spoolNotFound("5A3C9E21")) {
            try await session.saveWeight(row: rowID, grams: 700, mode: .gross)
        }
        #expect(inventory.updates.isEmpty)
    }

    @Test func savingOnTheHostRejectsOutOfRangeWeights() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)
        await #expect(throws: SessionError.invalidWeight(-1)) {
            try await session.saveWeight(row: rowID, grams: -1, mode: .gross)
        }
        await #expect(throws: SessionError.invalidWeight(10_000)) {
            try await session.saveWeight(row: rowID, grams: 10_000, mode: .gross)
        }
    }

    @Test func aFailedHostSaveMarksTheRow() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)
        inventory.updateError = .network("timed out")

        await #expect(throws: BambuddyError.network("timed out")) {
            try await session.saveWeight(row: rowID, grams: 700, mode: .gross)
        }
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))
    }

    @Test func anUnknownRowIdIsRejected() async throws {
        let session = makeSession(FakeInventory())
        let missing = UUID()
        await #expect(throws: SessionError.rowNotFound) {
            try await session.saveWeight(row: missing, grams: 10, mode: .gross)
        }
    }

    @Test func linkingOnTheHostAttachesTheTag() async throws {
        let handAdded = Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 100)
        let inventory = FakeInventory(spools: [handAdded])
        let session = makeSession(inventory)
        _ = await session.handleIntent(try fixtureIntent("intent_link_on_host"))
        let row = try #require(await session.rows.first)

        let linked = try await session.link(row: row.id, toSpool: 7)

        #expect(inventory.calls.last == .link(spoolId: 7, TagLink(tag: row.tag)))
        #expect(linked.tagUid == "04112233445566")
        #expect(linked.tagType == "ntag")
        let updated = try #require(await session.rows.first)
        #expect(updated.spool == linked)
        #expect(updated.status == .awaitingWeight)
        #expect(updated.request == nil)
    }

    @Test func aLinkConflictMarksTheRowAndRethrows() async throws {
        let inventory = FakeInventory(spools: [Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        inventory.linkError = .tagAlreadyLinked(otherSpoolId: 42)
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)

        await #expect(throws: BambuddyError.tagAlreadyLinked(otherSpoolId: 42)) {
            try await session.link(row: rowID, toSpool: 7)
        }
        #expect(await session.rows.first?.status == .error("Tag already linked to spool #42"))
    }

    @Test func creatingOnTheHostLinksTheRow() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleIntent(try fixtureIntent("intent_create_on_host"))
        let row = try #require(await session.rows.first)
        let form = ntagForm(row.tag)

        let created = try await session.createSpool(row: row.id, form)

        #expect(inventory.creates == [.create(form)])
        let updated = try #require(await session.rows.first)
        #expect(updated.spool == created)
        #expect(updated.status == .created)
        #expect(updated.savedBy == .host)
        #expect(updated.request == nil)
    }

    @Test func creatingOnTheHostUsesASpoolThatAlreadyCarriesTheTag() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.findError = .http(status: 500, message: "boom")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let row = try #require(await session.rows.first)
        #expect(FeedItem(row).offersUnknownActions)
        inventory.findError = nil
        let form = try #require(NewSpool(tag: row.tag, coreWeight: 250, coreWeightCatalogId: 3))

        let spool = try await session.createSpool(row: row.id, form)

        #expect(spool.id == 42)
        #expect(inventory.creates.isEmpty)
        let updated = try #require(await session.rows.first)
        #expect(updated.spool?.id == 42)
        #expect(updated.status == .awaitingWeight)
    }

    @Test func aFailedHostCreateMarksTheRowAndRethrows() async throws {
        let inventory = FakeInventory()
        inventory.createError = .http(status: 422, message: "material: field required")
        let session = makeSession(inventory)
        _ = await session.handleIntent(try fixtureIntent("intent_create_on_host"))
        let row = try #require(await session.rows.first)

        await #expect(throws: BambuddyError.http(status: 422, message: "material: field required")) {
            try await session.createSpool(row: row.id, ntagForm(row.tag))
        }
        let updated = try #require(await session.rows.first)
        #expect(updated.spool == nil)
        #expect(updated.status == .error("Bambuddy HTTP 422: material: field required"))
    }

    @Test func clearingTheFeedDuringAHostActionRejectsIt() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.spoolmanDelay = .milliseconds(100)
        let session = makeSession(inventory)
        let rowID = await session.record(try fixtureScan())

        let pending = Task { try await session.saveWeight(row: rowID, grams: 734, mode: .gross) }
        #expect(await eventually { inventory.calls.contains(.spoolman) })
        await session.clear()

        await #expect(throws: SessionError.rowNotFound) { try await pending.value }
        #expect(inventory.updates.isEmpty)
    }

    @Test func hostActionsNeedAReadyBambuddy() async throws {
        let inventory = FakeInventory()
        inventory.spoolman = true
        let session = makeSession(inventory)
        _ = await session.handleIntent(try fixtureIntent("intent_create_on_host"))
        let row = try #require(await session.rows.first)
        let form = ntagForm(row.tag)

        await #expect(throws: SessionError.notReady(BambuddyState.refused(.spoolmanMode).message!)) {
            try await session.createSpool(row: row.id, form)
        }
        #expect(inventory.creates.isEmpty)
    }
}
