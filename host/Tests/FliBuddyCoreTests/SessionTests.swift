import Foundation
import Testing
@testable import FliBuddyCore

/// The spool `lookup_found.json` describes, carrying the synthetic fixture's UID in
/// the AMS form.
func knownSpool(
    lastScaleWeight: Int? = 734, weightUsed: Double = 516, colorName: String? = "Jade White", subtype: String? = "Basic"
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

/// `scan_mfc.json` (or `name`) with the Flipper's Auto-save new on.
func autosaveScan(_ name: String = "scan_mfc") throws -> Scan {
    var scan = try fixtureScan(name)
    scan.autosave = true
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

    @Test func anUnknownTagWithMaterialIsCreatedOnScanWithAutosave() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try autosaveScan())

        #expect(inventory.creates.count == 1)
        #expect(lookup.status == .found)
        #expect(lookup.created)
        #expect(lookup.spool?.id == 100)
        #expect(lookup.spool?.remaining == 1000)
        let row = try #require(await session.rows.first)
        #expect(row.status == .created)
        #expect(row.savedBy == .host)
        #expect(row.createdSpoolId == 100)
    }

    @Test func theCreatedLookupMatchesTheFixture() async throws {
        let inventory = FakeInventory()
        inventory.colorMapAnswer = ColorMap(colors: ["ffffff": "Jade White"], byMaterial: [:])
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try autosaveScan("scan_mfc_autosave"))

        var expected = try fixtureLookup("lookup_created")
        // the fake numbers its spools from 100
        expected.spoolId = 100
        expected.spool?.id = 100
        #expect(lookup == expected)
    }

    @Test func withoutAutosaveAnUnknownTagStaysUnknownAndNothingIsCreated() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try fixtureScan())

        #expect(lookup == (try fixtureLookup("lookup_unknown")))
        #expect(inventory.writes.isEmpty)
        let row = try #require(await session.rows.first)
        #expect(row.status == .unknown(prefill: true))
        #expect(row.spool == nil)
        #expect(row.autosave == false)
    }

    @Test func autosaveCreatesNothingForATagWithoutMaterial() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try autosaveScan("scan_ntag"))

        #expect(lookup.status == .unknown)
        #expect(inventory.writes.isEmpty)
    }

    @Test func aRescanOfATagCreatedOnScanFindsItAndCreatesNothing() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try autosaveScan())

        var again = try autosaveScan()
        again.scanId = "s-000020"
        let lookup = await session.handleScan(again)

        #expect(lookup.status == .found)
        #expect(lookup.created == false)
        #expect(inventory.creates.count == 1)
        #expect(await session.rows.count == 1)
    }

    @Test func aRescanTakesTheNewScansAutosave() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        #expect(inventory.creates.isEmpty)

        var again = try autosaveScan()
        again.scanId = "s-000020"
        let lookup = await session.handleScan(again)

        #expect(lookup.created)
        #expect(await session.rows.first?.autosave == true)
        #expect(inventory.creates.count == 1)
    }

    @Test func aRowBeingCreatedOnScanStaysLookingUpUntilTheCreateReturns() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let seen = Recorded<FeedRow.Status?>()
        inventory.onCreate = { await seen.append(session.rows.first?.status) }

        _ = await session.handleScan(try autosaveScan())

        // Not "Not in Bambuddy" with New and Link while the create runs.
        #expect(await seen.values == [.scanned])
        #expect(await session.rows.first?.status == .created)
    }

    @Test func anUnknownTagWhoseCreateFailsOffersPrefill() async throws {
        let inventory = FakeInventory()
        inventory.createError = .network("timed out")
        let session = makeSession(inventory)

        let lookup = await session.handleScan(try autosaveScan())

        #expect(lookup == (try fixtureLookup("lookup_unknown")))
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))
    }

    @Test func unknownDefaultsUseTheConfiguredCoreWeight() async throws {
        var settings = testSettings
        settings.coreWeight = 180
        let inventory = FakeInventory()
        inventory.createError = .network("timed out")
        let session = makeSession(inventory, settings: settings)
        let lookup = await session.handleScan(try fixtureScan())
        #expect(lookup.defaults == Lookup.Defaults(label: 1000, core: 180))
    }

    @Test func aCreatedOnScanSpoolTakesTheConfiguredCoreWeight() async throws {
        var settings = testSettings
        settings.coreWeight = 180
        let session = makeSession(FakeInventory(), settings: settings)
        let lookup = await session.handleScan(try autosaveScan())
        #expect(lookup.defaults == Lookup.Defaults(gross: 1180, label: 1000, core: 180))
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
        #expect(await session.handle(.hello(Hello(app: "flibuddy", fw: "1.5.1"))) == nil)
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
        #expect(state.message?.contains("FliBuddy supports") == true)
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
        // the swatch shows the colour; the hex is never used as its name
        #expect(FeedItem(row).colorName == nil)
        #expect(FeedItem(row).swatch == Swatch(rgba: "A4DBE8FF"))
    }

    @Test func aFlipperNewSendsTheResolvedName() async throws {
        let inventory = namingInventory()
        let session = makeSession(inventory)
        _ = await session.checkBambuddy()
        _ = await session.record(try fixtureScan())
        let intent = try fixtureIntent("intent_new")

        let result = await session.handleIntent(intent)

        #expect(result.ok)
        let expected = try #require(
            NewSpool(tag: TagParser.parse(intent.tag), coreWeight: 250, coreWeightCatalogId: 3, colorName: "Jade White")
        )
        #expect(inventory.creates == [.create(expected)])
    }

    @Test func aFlipperNewAfterARestartSendsTheResolvedName() async throws {
        let inventory = namingInventory()
        let session = makeSession(inventory)
        let intent = try fixtureIntent("intent_new")

        let result = await session.handleIntent(intent)

        #expect(result.ok)
        guard case .create(let sent) = try #require(inventory.creates.first) else { return }
        #expect(sent.colorName == "Jade White")
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

        let lookup = await session.handleScan(try autosaveScan())
        #expect(lookup.status == .found)
        #expect(await session.bambuddy == .ready)
        let problem = try #require(await session.snapshot.colorNamesProblem)
        #expect(problem.hasPrefix("Colour names unavailable"))
        #expect(problem.contains("inventory:read"))

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

    @Test func newSettingsDuringTheMapLoadAreCheckedInstead() async throws {
        let old = namingInventory()
        old.colorMapDelay = .milliseconds(200)
        let session = makeSession(old)
        _ = await session.record(try fixtureScan())
        let stale = Task { await session.checkBambuddy() }
        try await Task.sleep(for: .milliseconds(50))

        let other = namingInventory()
        other.colorMapAnswer = ColorMap(colors: ["ffffff": "Snow"], byMaterial: [:])
        await session.reconfigure(settings: testSettings, inventory: other)

        #expect(await stale.value == .ready)
        #expect(await session.bambuddy == .ready)
        #expect(other.colorMapLoads == 1)
        #expect(await session.rows.first?.colorName == "Snow")
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

    @Test func newSettingsRenameTheRowsInTheFeed() async throws {
        let session = makeSession(namingInventory())
        _ = await session.handleScan(try fixtureScan())
        #expect(await session.rows.first?.colorName == "Jade White")

        let other = namingInventory()
        other.colorMapAnswer = ColorMap(colors: ["ffffff": "Snow"], byMaterial: [:])
        await session.reconfigure(settings: testSettings, inventory: other)
        #expect(await session.rows.first?.colorName == nil)
        _ = await session.checkBambuddy()

        #expect(await session.rows.first?.colorName == "Snow")
    }

    @Test func newSettingsWhoseMapFailsLeaveTheRowsUnnamed() async throws {
        let session = makeSession(namingInventory())
        _ = await session.handleScan(try fixtureScan())
        #expect(await session.rows.first?.colorName == "Jade White")

        let other = namingInventory()
        other.colorMapError = .network("timed out")
        await session.reconfigure(settings: testSettings, inventory: other)
        _ = await session.checkBambuddy()

        #expect(await session.snapshot.colorNamesProblem != nil)
        #expect(await session.rows.first?.colorName == nil)
    }

    @Test func overlappingChecksShareOneCheckAndOneMapLoad() async throws {
        let inventory = namingInventory()
        inventory.spoolmanDelay = .milliseconds(100)
        let session = makeSession(inventory)

        async let first = session.checkBambuddy()
        async let second = session.handleScan(try autosaveScan())
        let (state, lookup) = try await (first, second)

        #expect(state == .ready)
        #expect(lookup.status == .found)
        #expect(inventory.calls.filter { $0 == .spoolman }.count == 1)
        #expect(inventory.colorMapLoads == 1)
    }

    @Test func aCheckOfNewSettingsDoesNotReuseTheFinishedCheck() async throws {
        let old = FakeInventory()
        old.spoolmanDelay = .milliseconds(100)
        let session = makeSession(old)
        let first = Task { await session.checkBambuddy() }
        try await Task.sleep(for: .milliseconds(20))

        let other = FakeInventory()
        let state = await session.waitThenCheck(newInventory: other)
        _ = await first.value

        #expect(state == .ready)
        #expect(await session.bambuddy == .ready)
        #expect(other.calls.contains(.spoolman))
    }
}

extension Session {
    /// Waits for the check under way, then saves new settings and checks
    /// them in the same actor turn, before the first caller resumes.
    fileprivate func waitThenCheck(newInventory: FakeInventory) async -> BambuddyState {
        await checkBambuddy()
        reconfigure(settings: testSettings, inventory: newInventory)
        return await checkBambuddy()
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

    @Test func weighOnAnUnknownTagCreatesTheSpoolThenWeighsIt() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(result.lines == ["Saved", "484 g left"])
        #expect(result.spool?.id == 100)
        #expect(result.spool?.remaining == 484)
        let tag = TagParser.parse(try fixtureScan().tag)
        let expected = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(inventory.writes == [.create(expected), .update(spoolId: 100, gross: 734)])
        let row = try #require(await session.rows.first)
        #expect(row.status == .saved)
        #expect(row.spool?.id == 100)
        #expect(row.savedBy == .flipper)
        #expect(row.createdSpoolId == nil)
    }

    @Test func weighOnAnUnknownTagWithoutMaterialFailsWithoutAWrite() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        let scan = try fixtureScan("scan_ntag")
        _ = await session.handleScan(scan)
        var intent = try weighIntent(grams: 734, mode: .gross, scanId: scan.scanId)
        intent.tag = scan.tag

        let result = await session.handleIntent(intent)

        #expect(!result.ok)
        #expect(result.lines == ["Not saved", "Spool not found"])
        #expect(result.error == "no spool for tag 04112233445566")
        #expect(inventory.writes.isEmpty)
    }

    @Test func aRetryAfterTheCreateWentThroughAndTheWeightFailedCreatesNoSecondSpool() async throws {
        let inventory = FakeInventory()
        inventory.updateError = .network("timed out")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let intent = try weighIntent(grams: 734, mode: .gross)

        let first = await session.handleIntent(intent)
        #expect(!first.ok)
        #expect(first.lines == ["Not saved"])
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))

        inventory.updateError = nil
        let second = await session.handleIntent(intent)

        #expect(second.ok)
        #expect(inventory.creates.count == 1)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 734), .update(spoolId: 100, gross: 734)])
        #expect(await session.rows.first?.spool?.id == 100)
    }

    @Test func newCreatesWithTheConfiguredCatalogEntryAndLinksTheRow() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.record(try fixtureScan())
        let intent = try fixtureIntent("intent_new")

        let result = await session.handleIntent(intent)

        let tag = TagParser.parse(intent.tag)
        let expected = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(inventory.creates == [.create(expected)])
        #expect(expected.tagUid == "5A3C9E2100000100")
        #expect(expected.subtype == "Basic")
        #expect(result == IntentResult(
            id: "i-000004", ok: true, lines: ["Created", "spool #100"],
            spool: SpoolSummary(id: 100, material: "PLA", subtype: "Basic", rgba: "FFFFFFFF", remaining: 1000, label: 1000, core: 250)
        ))
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
        _ = await session.record(try fixtureScan())
        let intent = try fixtureIntent("intent_new")

        let first = await session.handleIntent(intent)
        #expect(!first.ok)
        #expect(first.lines == ["Not created"])
        #expect(first.error == "Bambuddy unreachable: timed out")
        #expect(await session.rows.first?.status == .error("Bambuddy unreachable: timed out"))
        #expect(await session.rows.first?.spool == nil)

        inventory.createError = nil
        let second = await session.handleIntent(intent)
        #expect(second.ok)
        #expect(second.lines == ["Created", "spool #100"])
        #expect(inventory.creates.count == 2)
    }

    @Test func aFailedLookupBeforeNewCreatesNothing() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.record(try fixtureScan())
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
        var intent = try weighIntent(grams: 734, mode: .gross, scanId: "s-000013")
        intent.tag = try fixtureScan("scan_ntag").tag

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

    @Test func savingOnTheHostForAnUnknownRowCreatesTheSpoolThenWeighsIt() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)

        try await session.saveWeight(row: rowID, grams: 700, mode: .gross)

        #expect(inventory.creates.count == 1)
        #expect(inventory.updates == [.update(spoolId: 100, gross: 700)])
        let row = try #require(await session.rows.first)
        #expect(row.status == .saved)
        #expect(row.savedBy == .host)
        #expect(row.spool?.remaining == 450)
    }

    @Test func savingOnTheHostForAnUnknownRowWithoutMaterialFails() async throws {
        let inventory = FakeInventory()
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan("scan_ntag"))
        let rowID = try #require(await session.rows.first?.id)

        await #expect(throws: SessionError.spoolNotFound("04112233445566")) {
            try await session.saveWeight(row: rowID, grams: 700, mode: .gross)
        }
        #expect(inventory.writes.isEmpty)
    }

    @Test func aHostSaveRetriedAfterTheWeightFailedCreatesNoSecondSpool() async throws {
        let inventory = FakeInventory()
        inventory.updateError = .network("timed out")
        let session = makeSession(inventory)
        _ = await session.handleScan(try fixtureScan())
        let rowID = try #require(await session.rows.first?.id)
        await #expect(throws: BambuddyError.network("timed out")) {
            try await session.saveWeight(row: rowID, grams: 700, mode: .gross)
        }

        inventory.updateError = nil
        try await session.saveWeight(row: rowID, grams: 700, mode: .gross)

        #expect(inventory.creates.count == 1)
        #expect(await session.rows.first?.status == .saved)
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

        let linked = try await session.link(row: row.id, toSpool: 7, from: try await session.listSpools())

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
            try await session.link(row: rowID, toSpool: 7, from: try await session.listSpools())
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

@Suite("Session: new settings")
struct SessionNewSettingsTests {
    /// A spool on another Bambuddy under the id the old one gave the tag's spool.
    private func strangerWithTheOldId() -> Spool {
        Spool(id: 42, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)
    }

    private func spoolOfTheTag(id: Int) -> Spool {
        var spool = knownSpool()
        spool.id = id
        return spool
    }

    @Test func aHostWeighLooksTheSpoolUpOnTheNewBambuddy() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        _ = await session.handleScan(try fixtureScan())
        let other = FakeInventory(spools: [strangerWithTheOldId(), spoolOfTheTag(id: 77)])
        await session.reconfigure(settings: testSettings, inventory: other)
        let row = try #require(await session.rows.first)
        #expect(row.spool?.id == 42)

        try await session.saveWeight(row: row.id, grams: 734, mode: .gross)

        #expect(other.updates == [.update(spoolId: 77, gross: 734)])
        #expect(await session.rows.first?.spool?.id == 77)
    }

    @Test func aFlipperWeighOfATagTheNewBambuddyLacksCreatesItThereAndLeavesTheStranger() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        _ = await session.handleScan(try fixtureScan())
        let other = FakeInventory(spools: [strangerWithTheOldId()])
        await session.reconfigure(settings: testSettings, inventory: other)

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(other.creates.count == 1)
        #expect(other.updates == [.update(spoolId: 100, gross: 734)])
        #expect(await session.rows.first?.spool?.id == 100)
    }

    @Test func aSpoolFoundOnTheNewBambuddyIsNotLookedUpAgain() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        _ = await session.handleScan(try fixtureScan())
        let other = FakeInventory(spools: [spoolOfTheTag(id: 77)])
        await session.reconfigure(settings: testSettings, inventory: other)
        let row = try #require(await session.rows.first)

        try await session.saveWeight(row: row.id, grams: 734, mode: .gross)
        try await session.saveWeight(row: row.id, grams: 700, mode: .gross)

        #expect(other.calls.filter { if case .find = $0 { true } else { false } }.count == 1)
        #expect(other.updates == [.update(spoolId: 77, gross: 734), .update(spoolId: 77, gross: 700)])
    }

    @Test func aCreateOnScanThatEndsAfterNewSettingsIsNotDeletedByLink() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        // spool 100 on the new Bambuddy is someone else's, under the id the old one gives the created spool
        let stranger = Spool(id: 100, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)
        let target = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let other = FakeInventory(spools: [stranger, target])
        old.onCreate = { await session.reconfigure(settings: testSettings, inventory: other) }

        let lookup = await session.handleScan(try autosaveScan())
        #expect(lookup.status == .found)
        let row = try #require(await session.rows.first)
        #expect(row.spool?.id == 100)
        #expect(row.createdSpoolId == nil)

        try await session.link(row: row.id, toSpool: 7, from: try await session.listSpools())

        #expect(!other.calls.contains { if case .delete = $0 { true } else { false } })
        #expect(other.spools.contains { $0.id == 100 })
    }

    @Test func aLookupThatEndsAfterNewSettingsCreatesNothingOnTheOldBambuddy() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        let other = FakeInventory(spools: [spoolOfTheTag(id: 77)])
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let lookup = await session.handleScan(try fixtureScan())

        #expect(old.creates.isEmpty)
        #expect(other.creates.isEmpty)
        #expect(lookup.status == .found)
        #expect(await session.rows.first?.spool?.id == 77)
    }

    @Test func aLookupThatFailsAfterNewSettingsAsksTheNewBambuddy() async throws {
        let old = FakeInventory()
        old.findError = .network("no answer within 5 s")
        let session = makeSession(old)
        let other = FakeInventory(spools: [spoolOfTheTag(id: 77)])
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let lookup = await session.handleScan(try fixtureScan())

        #expect(lookup.status == .found)
        #expect(await session.rows.first?.spool?.id == 77)
    }

    @Test func aWeighThatEndsAfterNewSettingsIsLookedUpAgain() async throws {
        let old = FakeInventory(spools: [knownSpool()])
        let session = makeSession(old)
        _ = await session.handleScan(try fixtureScan())
        let other = FakeInventory(spools: [strangerWithTheOldId(), spoolOfTheTag(id: 77)])
        old.updateDelay = .milliseconds(200)
        let row = try #require(await session.rows.first)
        let first = Task { try await session.saveWeight(row: row.id, grams: 734, mode: .gross) }
        try await Task.sleep(for: .milliseconds(50))

        await session.reconfigure(settings: testSettings, inventory: other)
        try await first.value
        try await session.saveWeight(row: row.id, grams: 700, mode: .gross)

        #expect(other.updates == [.update(spoolId: 77, gross: 700)])
    }

    @Test func aFlipperNewThatOutlivesTheSettingsCreatesOnTheNewBambuddyOnly() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        let other = FakeInventory()
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let result = await session.handleIntent(try fixtureIntent("intent_new"))

        #expect(result.ok)
        #expect(old.creates.isEmpty)
        #expect(other.creates.count == 1)
        #expect(await session.rows.first?.spool?.id == 100)
    }

    @Test func aHostNewThatOutlivesTheSettingsCreatesNothing() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        let rowID = await session.record(try fixtureScan())
        let row = try #require(await session.rows.first)
        let form = try #require(NewSpool(tag: row.tag, coreWeight: 250, coreWeightCatalogId: 3, colorName: nil))
        let other = FakeInventory()
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        await #expect(throws: SessionError.settingsChanged) {
            try await session.createSpool(row: rowID, form)
        }

        #expect(old.creates.isEmpty)
        #expect(other.creates.isEmpty)
        #expect(await session.rows.first?.status == .error(SessionError.settingsChanged.localizedDescription))
    }

    @Test func aHostNewDoesNotTakeASpoolFoundOnTheOldBambuddy() async throws {
        let old = FakeInventory(spools: [knownSpool()])
        let session = makeSession(old)
        let rowID = await session.record(try fixtureScan())
        let row = try #require(await session.rows.first)
        let form = try #require(NewSpool(tag: row.tag, coreWeight: 250, coreWeightCatalogId: 3, colorName: nil))
        let other = FakeInventory()
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        await #expect(throws: SessionError.settingsChanged) {
            try await session.createSpool(row: rowID, form)
        }

        #expect(await session.rows.first?.spool == nil)
        #expect(other.creates.isEmpty)
    }

    @Test func aFlipperNewDoesNotReportASpoolFoundOnTheOldBambuddy() async throws {
        let old = FakeInventory(spools: [knownSpool()])
        let session = makeSession(old)
        let other = FakeInventory()
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let result = await session.handleIntent(try fixtureIntent("intent_new"))

        #expect(result.ok)
        #expect(result.lines.first == "Created")
        #expect(old.creates.isEmpty)
        #expect(other.creates.count == 1)
    }

    @Test func aFlipperNewWhoseCreateWasSentBeforeNewSettingsIsNotRepeated() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        let other = FakeInventory()
        old.onCreate = { await session.reconfigure(settings: testSettings, inventory: other) }

        let result = await session.handleIntent(try fixtureIntent("intent_new"))

        #expect(result.ok)
        #expect(result.lines == ["Created", "spool #100"])
        #expect(old.creates.count == 1)
        #expect(other.calls.isEmpty)
        // the spool is the old Bambuddy's: not one Link may delete
        #expect(await session.rows.first?.createdSpoolId == nil)
    }

    @Test func aHostNewWhoseCreateWasSentBeforeNewSettingsIsKept() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        let rowID = await session.record(try fixtureScan())
        let row = try #require(await session.rows.first)
        let form = try #require(NewSpool(tag: row.tag, coreWeight: 250, coreWeightCatalogId: 3, colorName: nil))
        let other = FakeInventory()
        old.onCreate = { await session.reconfigure(settings: testSettings, inventory: other) }

        let created = try await session.createSpool(row: rowID, form)

        #expect(created.id == 100)
        #expect(old.creates.count == 1)
        #expect(other.calls.isEmpty)
        #expect(await session.rows.first?.status == .created)
        #expect(await session.rows.first?.createdSpoolId == nil)
    }

    @Test func aFlipperWeighDoesNotTakeTheOldBambuddysMissingSpool() async throws {
        let old = FakeInventory()
        let session = makeSession(old)
        _ = await session.record(try fixtureScan())
        let other = FakeInventory(spools: [spoolOfTheTag(id: 77)])
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(other.updates == [.update(spoolId: 77, gross: 734)])
        #expect(await session.rows.first?.spool?.id == 77)
    }

    @Test func aFlipperWeighWhoseFindFailsAfterNewSettingsAsksTheNewBambuddy() async throws {
        let old = FakeInventory()
        old.findError = .network("no answer within 5 s")
        let session = makeSession(old)
        _ = await session.record(try fixtureScan())
        let other = FakeInventory(spools: [spoolOfTheTag(id: 77)])
        old.onFind = { await session.reconfigure(settings: testSettings, inventory: other) }

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(result.ok)
        #expect(other.updates == [.update(spoolId: 77, gross: 734)])
    }

    @Test func aPickFromAListOfOlderSettingsLinksNothing() async throws {
        let old = FakeInventory(spools: [Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        let session = makeSession(old)
        _ = await session.handleIntent(try fixtureIntent("intent_link_on_host"))
        let row = try #require(await session.rows.first)
        let listing = try await session.listSpools()
        // spool 7 on the new Bambuddy is someone else's
        let other = FakeInventory(spools: [Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        await session.reconfigure(settings: testSettings, inventory: other)

        await #expect(throws: SessionError.staleSpoolList) {
            try await session.link(row: row.id, toSpool: 7, from: listing)
        }

        #expect(!other.calls.contains { if case .link = $0 { true } else { false } })
        #expect(other.spools.first?.tagUid == nil)
    }

    @Test func aListThatOutlivesTheSettingsIsAListOfTheOldOnes() async throws {
        let old = FakeInventory(spools: [Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        let session = makeSession(old)
        _ = await session.handleIntent(try fixtureIntent("intent_link_on_host"))
        let row = try #require(await session.rows.first)
        let other = FakeInventory(spools: [Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        old.onList = { await session.reconfigure(settings: testSettings, inventory: other) }
        let listing = try await session.listSpools()

        await #expect(throws: SessionError.staleSpoolList) {
            try await session.link(row: row.id, toSpool: 7, from: listing)
        }

        #expect(!other.calls.contains { if case .link = $0 { true } else { false } })
    }
}

/// Values a test callback saw, in order.
actor Recorded<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }
}

@Suite("Session: log")
struct SessionLogTests {
    /// A clock that stands still, so lookups take 0 ms.
    private func makeSession(_ inventory: FakeInventory?, settings: Settings = testSettings) -> Session {
        Session(settings: settings, inventory: inventory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func tray() throws -> String {
        try #require(TagParser.parse(try fixtureScan().tag).trayUuid)
    }

    @Test func aScanAndAFoundLookupAreLogged() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))

        let sink = try await capturingLog { _ = await session.handleScan(try fixtureScan()) }

        #expect(sink.events("session") == [
            "session scan: id=s-000012 uid=5A3C9E21 tray=\(try tray()) kind=mfc material=PLA autosave=false",
            "session bambuddy: ready",
            "session lookup: id=s-000012 status=found spool=42 ms=0",
        ])
    }

    @Test func anNTAGScanWithoutMaterialSaysNone() async throws {
        let session = makeSession(FakeInventory())

        let sink = try await capturingLog { _ = await session.handleScan(try fixtureScan("scan_ntag")) }

        #expect(sink.events("session scan") == ["session scan: id=s-000013 uid=04112233445566 tray=none kind=ntag material=none autosave=false"])
        #expect(sink.events("session lookup") == ["session lookup: id=s-000013 status=not_found ms=0"])
    }

    @Test func aCreateOnScanIsLogged() async throws {
        let session = makeSession(FakeInventory())

        let sink = try await capturingLog { _ = await session.handleScan(try autosaveScan()) }

        #expect(sink.events("session create") == ["session create on scan: id=s-000012 spool=100"])
        #expect(sink.events("session lookup") == ["session lookup: id=s-000012 status=created spool=100 ms=0"])
    }

    @Test func aFailedCreateOnScanIsLoggedAsAnError() async throws {
        let inventory = FakeInventory()
        inventory.createError = .network("timed out")
        let session = makeSession(inventory)

        let sink = try await capturingLog { _ = await session.handleScan(try autosaveScan()) }

        let failed = sink.lines.filter { $0.message.hasPrefix("create on scan failed:") }
        #expect(failed.map(\.message) == ["create on scan failed: id=s-000012 error=Bambuddy unreachable: timed out"])
        #expect(failed.map(\.level) == [.error])
        #expect(sink.events("session lookup") == ["session lookup: id=s-000012 status=not_found ms=0"])
    }

    @Test func aFailedLookupIsLoggedAsAnErrorWithTheElapsedTime() async throws {
        let inventory = FakeInventory()
        inventory.findError = .network("connection timed out")
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        inventory.onFind = { clock.mutate { $0 += 0.043 } }
        let session = Session(settings: testSettings, inventory: inventory, now: { clock.value })

        let sink = try await capturingLog { _ = await session.handleScan(try fixtureScan()) }

        let lookups = sink.lines.filter { $0.message.hasPrefix("lookup:") }
        #expect(lookups.map(\.message) == [
            "lookup: id=s-000012 status=error ms=43 error=Bambuddy unreachable: connection timed out"
        ])
        #expect(lookups.map(\.level) == [.error])
    }

    @Test func aLookupForAClearedRowIsLogged() async throws {
        let session = makeSession(FakeInventory())
        let sink = await capturingLog { _ = await session.lookup(row: UUID()) }
        #expect(sink.events("session lookup") == ["session lookup: id=unknown status=error ms=0 error=row cleared"])
    }

    @Test func everyBambuddyStateChangeIsLoggedWithItsMessage() async throws {
        let inventory = FakeInventory()
        inventory.spoolmanError = .unauthorized
        let session = makeSession(inventory)

        let sink = await capturingLog {
            await session.checkBambuddy()
            await session.checkBambuddy()
            await session.reconfigure(settings: testSettings, inventory: nil)
            await session.checkBambuddy()
        }

        #expect(sink.events("session bambuddy") == [
            "session bambuddy: refused message=Bambuddy rejected the API key; check it in Settings",
            "session bambuddy: unchecked",
            "session bambuddy: notConfigured message=Set the Bambuddy URL and API key in Settings",
        ])
        #expect(sink.lines.filter { $0.message.hasPrefix("bambuddy:") }.map(\.level) == [.error, .info, .notice])
    }

    @Test func anUnreachableOrRefusingBambuddyKeepsItsWordsThroughRedaction() async throws {
        let inventory = FakeInventory()
        inventory.spoolmanError = .permissionMissing("settings:read")
        let session = makeSession(inventory)

        let sink = await capturingLog {
            await session.checkBambuddy()
            inventory.spoolmanError = .network("no answer within 5 s")
            await session.reconfigure(settings: testSettings, inventory: inventory)
            await session.checkBambuddy()
        }

        #expect(sink.events("session bambuddy") == [
            "session bambuddy: refused message=API key lacks the settings:read permission; add it to the key in Bambuddy",
            "session bambuddy: unchecked",
            "session bambuddy: unreachable message=Bambuddy unreachable: no answer within 5 s",
        ])
    }

    @Test func anIntentAndItsResultAreLogged() async throws {
        let session = makeSession(FakeInventory(spools: [knownSpool()]))
        _ = await session.handleScan(try fixtureScan())

        let sink = try await capturingLog { _ = await session.handleIntent(try fixtureIntent("intent_weigh")) }

        #expect(sink.events("session") == [
            "session intent: id=i-000003 action=weigh spool=42 grams=734 mode=gross",
            "session result: id=i-000003 ok",
        ])
    }

    @Test func anIntentForATagTheHostHasNotSeenHasNoSpool() async throws {
        let session = makeSession(FakeInventory())

        let sink = try await capturingLog { _ = await session.handleIntent(try fixtureIntent("intent_new")) }

        #expect(sink.events("session intent") == ["session intent: id=i-000004 action=new spool=none"])
        #expect(sink.events("session result") == ["session result: id=i-000004 ok"])
    }

    @Test func aFailedIntentIsLoggedAsAnError() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.updateError = .network("timed out")
        let session = makeSession(inventory)

        let sink = try await capturingLog { _ = await session.handleIntent(try fixtureIntent("intent_weigh")) }

        let results = sink.lines.filter { $0.message.hasPrefix("result:") }
        #expect(results.map(\.message) == ["result: id=i-000003 error=Bambuddy unreachable: timed out"])
        #expect(results.map(\.level) == [.error])
    }

    @Test func aLinkThatDeletesTheSpoolCreatedOnScanLogsBoth() async throws {
        let inventory = FakeInventory(spools: [Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        let session = makeSession(inventory)
        _ = await session.handleScan(try autosaveScan())
        let rowID = try #require(await session.rows.first?.id)
        let listing = try await session.listSpools()

        let sink = try await capturingLog { _ = try await session.link(row: rowID, toSpool: 7, from: listing) }

        #expect(sink.events("session") == [
            "session delete: id=s-000012 spool=100",
            "session link: id=s-000012 spool=7",
        ])
    }

    @Test func aFailedDeleteIsLoggedAndNoLinkFollows() async throws {
        let inventory = FakeInventory(spools: [Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        inventory.deleteError = .http(status: 500, message: "boom")
        let session = makeSession(inventory)
        _ = await session.handleScan(try autosaveScan())
        let rowID = try #require(await session.rows.first?.id)
        let listing = try await session.listSpools()

        let sink = await capturingLog { _ = try? await session.link(row: rowID, toSpool: 7, from: listing) }

        let failed = sink.lines.filter { $0.category == .session }
        #expect(failed.map(\.message) == [
            "delete failed: id=s-000012 spool=100 error=Spool 100 created on scan could not be deleted, "
                + "so the tag stays on it: Bambuddy HTTP 500: boom"
        ])
        #expect(failed.map(\.level) == [.error])
    }

    @Test func aFailedLinkIsLoggedAsAnError() async throws {
        let inventory = FakeInventory(spools: [Spool(id: 7, material: "PETG", labelWeight: 1000, coreWeight: 250, weightUsed: 0)])
        inventory.linkError = .tagAlreadyLinked(otherSpoolId: 42)
        let session = makeSession(inventory)
        _ = await session.handleIntent(try fixtureIntent("intent_link_on_host"))
        let rowID = try #require(await session.rows.first?.id)
        let listing = try await session.listSpools()

        let sink = await capturingLog { _ = try? await session.link(row: rowID, toSpool: 7, from: listing) }

        let failed = sink.lines.filter { $0.category == .session }
        #expect(failed.map(\.message) == ["link failed: id=s-000013 spool=7 error=Tag already linked to spool #42"])
        #expect(failed.map(\.level) == [.error])
    }

    @Test func aHostCreateAndItsFailureAreLogged() async throws {
        let failing = FakeInventory()
        failing.createError = .network("timed out")
        let sessions = [makeSession(FakeInventory()), makeSession(failing)]
        var rows: [FeedRow] = []
        for session in sessions {
            _ = await session.handleIntent(try fixtureIntent("intent_create_on_host"))
            rows.append(try #require(await session.rows.first))
        }

        let sink = await capturingLog {
            for (session, row) in zip(sessions, rows) {
                _ = try? await session.createSpool(row: row.id, ntagForm(row.tag))
            }
        }

        let created = sink.lines.filter { $0.message.hasPrefix("create") }
        #expect(created.map(\.message) == [
            "create: id=s-000013 spool=100",
            "create failed: id=s-000013 error=Bambuddy unreachable: timed out",
        ])
        #expect(created.map(\.level) == [.info, .error])
    }
}
