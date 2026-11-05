import Foundation
import Testing
@testable import FliBuddyCore

private struct NoClient: Error, LocalizedError {
    var errorDescription: String? { "no client" }
}

@MainActor
private func makeModel(
    _ inventory: FakeInventory? = FakeInventory(),
    settings: Settings = testSettings,
    ports: [String] = ["/dev/cu.usbmodemflip_Anmaa1"],
    scan: @escaping @MainActor () -> AsyncStream<DiscoveredPeripheral> = { AsyncStream { $0.finish() } },
    scanDuration: Duration = .seconds(15),
    power: @escaping @MainActor () async -> BLEPowerState = { .poweredOn },
    connected: @escaping @MainActor () -> TransportKind? = { nil },
    appliesOnChange: Bool = false,
    requiresHTTPS: Bool = false,
    apply: @escaping @MainActor (Settings) async throws -> Void = { _ in }
) -> SettingsViewModel {
    SettingsViewModel(
        settings: settings,
        makeInventory: { _ in
            guard let inventory else { throw NoClient() }
            return inventory
        },
        discoverPorts: { ports },
        discoverFlippers: scan,
        bluetoothPower: power,
        scanDuration: scanDuration,
        connectedTransport: connected,
        appliesOnChange: appliesOnChange,
        requiresHTTPS: requiresHTTPS,
        apply: apply
    )
}

private let flipperA = DiscoveredPeripheral(
    id: UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")!, name: "Flipper Anmaa1", rssi: -60
)
private let flipperB = DiscoveredPeripheral(
    id: UUID(uuidString: "0F1C2E3D-4B5A-4978-8695-A4B3C2D1E0F9")!, name: "Flipper Brrr2", rssi: -75
)

/// A scan the test feeds by hand; `stopped` turns true when the consumer stops.
@MainActor
private final class ManualScan {
    private(set) var continuation: AsyncStream<DiscoveredPeripheral>.Continuation?
    let stopped = LockedBox(false)
    private(set) var starts = 0

    func start() -> AsyncStream<DiscoveredPeripheral> {
        starts += 1
        let (stream, continuation) = AsyncStream<DiscoveredPeripheral>.makeStream()
        let stopped = stopped
        stopped.mutate { $0 = false }
        continuation.onTermination = { _ in stopped.mutate { $0 = true } }
        self.continuation = continuation
        return stream
    }
}

/// A scanner that answers with `result` and counts its scans.
@MainActor
private final class FakeQRScanner: QRScanning {
    private let result: Result<String, any Error>
    private(set) var scans = 0

    init(_ result: Result<String, any Error>) {
        self.result = result
    }

    func scan() async throws -> String {
        scans += 1
        return try result.get()
    }
}

private struct CameraFailed: Error, LocalizedError {
    var errorDescription: String? { "camera unavailable" }
}

private let bambuddyQR = "bambuddy://config?v=1&url=http%3A%2F%2F192.168.1.10%3A8000&key=bb_from_qr"

@MainActor
@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    @Test func theDraftStartsAsTheSavedSettings() {
        var settings = testSettings
        settings.port = "/dev/cu.usbmodemflip_X1"
        let model = makeModel(settings: settings)
        #expect(model.baseURL == "http://bambuddy.test:8000")
        #expect(model.apiKey == "bb_test")
        #expect(model.catalogEntryId == 3)
        #expect(model.coreWeight == 250)
        #expect(model.defaultMode == .gross)
        #expect(model.port == "/dev/cu.usbmodemflip_X1")
        #expect(model.draft == settings)
        #expect(!model.hasChanges)
    }

    @Test func editsShowInTheDraft() {
        let model = makeModel()
        model.baseURL = "http://10.0.0.5:8000"
        model.defaultMode = .net
        #expect(model.hasChanges)
        #expect(model.draft.baseURL == "http://10.0.0.5:8000")
        #expect(model.draft.defaultMode == .net)
        #expect(model.draft.apiKey == "bb_test")
    }

    @Test func aGoodConnectionLoadsTheCatalog() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [
            CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250),
            CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180),
        ]
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .ready)
        #expect(model.catalog.map(\.id) == [3, 9])
        #expect(inventory.calls.contains(.spoolman))
        #expect(inventory.colorMapLoads == 0)
    }

    @Test func aCatalogTheKeyCannotReadFailsTheTest() async {
        let inventory = FakeInventory()
        inventory.catalogError = .permissionMissing("inventory:read")
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .failed(BambuddyState.refused(.permissionMissing("inventory:read")).message!))
        #expect(model.catalogError != nil)
    }

    @Test func aRejectedCatalogFailsTheTest() async {
        let inventory = FakeInventory()
        inventory.catalogError = .unauthorized
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .failed(BambuddyState.refused(.unauthorized).message!))
    }

    @Test func anUnreachableCatalogFailsTheTest() async {
        let inventory = FakeInventory()
        inventory.catalogError = .network("no answer within 5 s")
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .unreachable("no answer within 5 s"))
    }

    @Test func aTestOfAnEditedURLShowsNoResult() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onSpoolman = { await MainActor.run { model.baseURL = "http://other.local:8000" } }

        await model.testConnection()

        #expect(model.connection == nil)
    }

    @Test func aTestOfAnEditedKeyKeepsTheCatalog() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onCatalog = { await MainActor.run { model.apiKey = "bb_other" } }

        await model.testConnection()

        #expect(model.connection == nil)
        #expect(model.catalog.isEmpty)
    }

    @Test func editingTheURLOrKeyDropsTheResult() async {
        let model = makeModel()
        await model.testConnection()
        #expect(model.connection == .ready)

        model.baseURL = "http://other.local:8000"
        #expect(model.connection == nil)

        await model.testConnection()
        model.apiKey = "bb_other"
        #expect(model.connection == nil)
    }

    @Test func editingOtherFieldsKeepsTheResult() async {
        let model = makeModel()
        await model.testConnection()

        model.coreWeight = 300
        model.defaultMode = .net

        #expect(model.connection == .ready)
    }

    @Test func spoolmanModeFailsTheTest() async {
        let inventory = FakeInventory()
        inventory.spoolman = true
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .failed(BambuddyState.refused(.spoolmanMode).message!))
    }

    @Test func aMissingPermissionIsNamed() async {
        let inventory = FakeInventory()
        inventory.spoolmanError = .permissionMissing("settings:read")
        let model = makeModel(inventory)

        await model.testConnection()

        guard case .failed(let message) = model.connection else {
            Issue.record("expected a failure, got \(String(describing: model.connection))")
            return
        }
        #expect(message.contains("settings:read"))
    }

    @Test func incompleteSettingsFailTheTestWithoutACall() async {
        let model = makeModel(nil)
        await model.testConnection()
        #expect(model.connection == .failed("no client"))
    }

    @Test func choosingACatalogEntrySetsTheCoreWeight() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180)]
        let model = makeModel(inventory)
        await model.loadCatalog()

        model.catalogEntryId = 9

        #expect(model.draft.catalogEntryId == 9)
        #expect(model.draft.coreWeight == 180)
    }

    @Test func anUnloadedCatalogKeepsTheSavedCoreWeight() {
        var settings = testSettings
        settings.coreWeight = 210
        let model = makeModel(settings: settings)
        #expect(model.draft.coreWeight == 210)
    }

    @Test func aLoadedCatalogDoesNotOverwriteTheSavedCoreWeight() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250)]
        var settings = testSettings
        settings.coreWeight = 242
        let model = makeModel(inventory, settings: settings)

        await model.loadCatalog()

        #expect(model.draft.coreWeight == 242)
        #expect(!model.hasChanges)
    }

    @Test func editingAfterPickingAnEntryKeepsTheEdit() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180)]
        var applied: [Settings] = []
        let model = makeModel(inventory, apply: { applied.append($0) })
        await model.loadCatalog()

        model.catalogEntryId = 9
        model.coreWeight = 242

        #expect(await model.save())
        #expect(applied.map(\.coreWeight) == [242])
        #expect(applied.map(\.catalogEntryId) == [9])
    }

    @Test func reselectingTheSameEntryKeepsTheEdit() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250)]
        let model = makeModel(inventory)
        await model.loadCatalog()

        model.coreWeight = 242
        model.catalogEntryId = 3

        #expect(model.draft.coreWeight == 242)
    }

    @Test func anEditedCoreWeightIsSavedWithoutACatalog() async {
        var applied: [Settings] = []
        let model = makeModel(apply: { applied.append($0) })

        model.coreWeight = 242

        #expect(model.hasChanges)
        #expect(await model.save())
        #expect(applied.map(\.coreWeight) == [242])
    }

    @Test(arguments: [0, -5, 5001])
    func anOutOfRangeCoreWeightIsRejected(weight: Int) async {
        var applied: [Settings] = []
        let model = makeModel(apply: { applied.append($0) })

        model.coreWeight = weight

        #expect(model.coreWeightError == "Core weight must be 1–5000 g")
        #expect(!(await model.save()))
        #expect(applied.isEmpty)
        #expect(model.saveError == "Core weight must be 1–5000 g")
    }

    @Test(arguments: [1, 242, 5000])
    func anInRangeCoreWeightIsAccepted(weight: Int) async {
        let model = makeModel()
        model.coreWeight = weight
        #expect(model.coreWeightError == nil)
        #expect(await model.save())
    }

    @Test func aFailedCatalogLoadIsReported() async {
        let inventory = FakeInventory()
        inventory.catalogError = .unauthorized
        let model = makeModel(inventory)

        await model.loadCatalog()

        #expect(model.catalog.isEmpty)
        #expect(model.catalogError == BambuddyError.unauthorized.localizedDescription)
    }

    @Test func anOlderCatalogLoadThatFailsLastChangesNothing() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onCatalog = {
            inventory.onCatalog = nil
            await model.loadCatalog()
            inventory.catalogError = .network("no answer within 5 s")
        }

        await model.loadCatalog()

        #expect(model.catalog.map(\.id) == [3])
        #expect(model.catalogError == nil)
    }

    @Test func anOlderCatalogLoadThatSucceedsLastChangesNothing() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onCatalog = {
            inventory.onCatalog = nil
            inventory.catalogError = .unauthorized
            await model.loadCatalog()
            inventory.catalogError = nil
        }

        await model.loadCatalog()

        #expect(model.catalog.isEmpty)
        #expect(model.catalogError == BambuddyError.unauthorized.localizedDescription)
    }

    @Test func aCatalogLoadThatEndsAfterATestKeepsTheTestsCatalog() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onCatalog = {
            inventory.onCatalog = nil
            await model.testConnection()
            inventory.catalogError = .network("no answer within 5 s")
        }

        await model.loadCatalog()

        #expect(model.connection == .ready)
        #expect(model.catalog.map(\.id) == [3])
        #expect(model.catalogError == nil)
    }

    @Test func aTestWhoseCatalogLoadEndsAfterANewerOneStillShowsItsResult() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onCatalog = {
            inventory.onCatalog = nil
            await model.loadCatalog()
            inventory.catalogError = .network("no answer within 5 s")
        }

        await model.testConnection()

        #expect(model.connection == .unreachable("no answer within 5 s"))
        #expect(model.catalog.map(\.id) == [3])
        #expect(model.catalogError == nil)
    }

    @Test func aCatalogLoadWithoutAClientIsReported() async {
        let model = makeModel(nil)

        await model.loadCatalog()

        #expect(model.catalog.isEmpty)
        #expect(model.catalogError == "no client")
    }

    @Test func portsComeFromDiscovery() {
        let model = makeModel(ports: ["/dev/cu.usbmodemflip_A", "/dev/cu.usbmodemflip_B"])
        #expect(model.ports.isEmpty)
        model.refreshPorts()
        #expect(model.ports == ["/dev/cu.usbmodemflip_A", "/dev/cu.usbmodemflip_B"])
    }

    @Test func aChosenPortThatIsGoneStaysListed() {
        var settings = testSettings
        settings.port = "/dev/cu.usbmodemflip_Gone"
        let model = makeModel(settings: settings, ports: ["/dev/cu.usbmodemflip_A"])
        model.refreshPorts()
        #expect(model.ports == ["/dev/cu.usbmodemflip_A", "/dev/cu.usbmodemflip_Gone"])
    }

    @Test func savingAppliesTheDraft() async {
        var applied: [Settings] = []
        let model = makeModel(apply: { applied.append($0) })
        model.apiKey = "bb_new"

        #expect(await model.save())

        #expect(applied.map(\.apiKey) == ["bb_new"])
        #expect(!model.hasChanges)
        #expect(model.saveError == nil)
    }

    @Test func aFailedSaveIsReported() async {
        let model = makeModel(apply: { _ in throw SecretStoreError.status(-25300) })
        model.apiKey = "bb_new"

        #expect(!(await model.save()))

        #expect(model.saveError != nil)
        #expect(model.hasChanges)
    }

    @Test func theDraftCarriesTheTransportSettings() {
        var settings = testSettings
        settings.transport = .bluetooth
        settings.peripheralId = flipperA.id
        settings.peripheralName = flipperA.name
        let model = makeModel(settings: settings)
        #expect(model.transport == .bluetooth)
        #expect(model.peripheralId == flipperA.id)
        #expect(model.peripheralName == flipperA.name)
        #expect(model.draft == settings)

        model.transport = .usb
        #expect(model.draft.transport == .usb)
        #expect(model.hasChanges)
    }

    @Test func theTransportPickerOffersThePlatformKinds() {
        let model = makeModel()
        #expect(model.availableTransports == TransportKind.available)
        #if os(macOS)
        #expect(model.showsUSB)
        #else
        #expect(!model.showsUSB)
        #endif
    }

    @Test func scanningListsEachFlipperOnceWithTheLatestSignal() async {
        let scan = ManualScan()
        let model = makeModel(scan: scan.start)

        model.scanForFlippers()
        #expect(model.isScanning)
        scan.continuation?.yield(flipperA)
        scan.continuation?.yield(flipperB)
        var closer = flipperA
        closer.rssi = -40
        scan.continuation?.yield(closer)

        #expect(await eventually { model.discovered == [closer, flipperB] })
        model.stopScanning()
    }

    @Test func aNewScanStartsWithAnEmptyList() async {
        let scan = ManualScan()
        let model = makeModel(scan: scan.start)
        model.scanForFlippers()
        scan.continuation?.yield(flipperA)
        #expect(await eventually { model.discovered == [flipperA] })

        model.scanForFlippers()

        #expect(model.discovered.isEmpty)
        #expect(scan.starts == 2)
        model.stopScanning()
    }

    @Test func stoppingEndsTheScan() async {
        let scan = ManualScan()
        let model = makeModel(scan: scan.start)
        model.scanForFlippers()

        model.stopScanning()

        #expect(!model.isScanning)
        #expect(await eventually { scan.stopped.value })
    }

    @Test func theScanStopsByItselfAfterAWhile() async {
        let scan = ManualScan()
        let model = makeModel(scan: scan.start, scanDuration: .milliseconds(50))

        model.scanForFlippers()

        #expect(await eventually { !model.isScanning })
        #expect(await eventually { scan.stopped.value })
    }

    @Test func aScanThatEndsClearsTheScanningFlag() async {
        let model = makeModel(scan: {
            AsyncStream { continuation in
                continuation.yield(flipperA)
                continuation.finish()
            }
        })

        model.scanForFlippers()

        #expect(await eventually { !model.isScanning })
        #expect(model.discovered == [flipperA])
    }

    @Test(arguments: [
        (BLEPowerState.poweredOff, "Bluetooth is off"),
        (.unauthorized, "FliBuddy is not allowed to use Bluetooth"),
        (.unsupported, "This device has no Bluetooth LE"),
    ])
    func aScanWithoutTheRadioSaysWhyAndStops(power: BLEPowerState, problem: String) async {
        let scan = ManualScan()
        let model = makeModel(scan: scan.start, power: { power })

        model.scanForFlippers()

        #expect(await eventually { model.scanProblem == problem })
        #expect(!model.isScanning)
        #expect(await eventually { scan.stopped.value })
    }

    @Test func aScanWithTheRadioOnHasNoProblem() async {
        let scan = ManualScan()
        let power = LockedBox(BLEPowerState.poweredOff)
        let model = makeModel(scan: scan.start, power: { power.value })
        model.scanForFlippers()
        #expect(await eventually { model.scanProblem != nil })
        power.mutate { $0 = .poweredOn }

        model.scanForFlippers()

        #expect(model.scanProblem == nil)
        scan.continuation?.yield(flipperA)
        #expect(await eventually { model.discovered == [flipperA] })
        #expect(model.isScanning)
        #expect(model.scanProblem == nil)
        model.stopScanning()
    }

    @Test func choosingAFlipperStoresItsIdAndNameAndStopsTheScan() async {
        let scan = ManualScan()
        var applied: [Settings] = []
        let model = makeModel(scan: scan.start, apply: { applied.append($0) })
        model.scanForFlippers()

        model.choosePeripheral(flipperB)

        #expect(model.peripheralId == flipperB.id)
        #expect(model.peripheralName == "Flipper Brrr2")
        #expect(model.transport == .bluetooth)
        #expect(!model.isScanning)
        #expect(await eventually { scan.stopped.value })
        #expect(await model.save())
        #expect(applied.map(\.peripheralId) == [flipperB.id])
        #expect(applied.map(\.peripheralName) == ["Flipper Brrr2"])
    }

    @Test func forgettingTheFlipperClearsIt() {
        var settings = testSettings
        settings.transport = .bluetooth
        settings.peripheralId = flipperA.id
        settings.peripheralName = flipperA.name
        let model = makeModel(settings: settings)

        model.forget()

        #expect(model.peripheralId == nil)
        #expect(model.peripheralName == nil)
        #expect(model.draft.peripheralId == nil)
        #expect(model.draft.peripheralName == nil)
        #expect(model.draft.transport == .bluetooth)
        #expect(model.hasChanges)
    }

    @Test func aQRPayloadFillsTheURLAndKey() async {
        let model = makeModel()
        await model.testConnection()
        #expect(model.connection == .ready)

        model.applyQRPayload(bambuddyQR)

        #expect(model.baseURL == "http://192.168.1.10:8000")
        #expect(model.apiKey == "bb_from_qr")
        #expect(model.qrStatus == .applied("Filled from the QR code."))
        // The last test was for the old server.
        #expect(model.connection == nil)
        #expect(model.hasChanges)
        #expect(model.draft.catalogEntryId == 3)
        #expect(model.draft.coreWeight == 250)
    }

    @Test func aWrongQRCodeLeavesTheFieldsAndSaysWhy() {
        let model = makeModel()

        model.applyQRPayload("bambuddy://config?v=2&url=http%3A%2F%2Fa.lan&key=k")

        #expect(model.baseURL == "http://bambuddy.test:8000")
        #expect(model.apiKey == "bb_test")
        #expect(model.qrStatus == .failed(APIKeyQRPayload.ParseError.unsupportedVersion("2").localizedDescription))
        #expect(!model.hasChanges)
    }

    @Test func scanningAppliesWhatTheScannerRead() async {
        let model = makeModel()
        let scanner = FakeQRScanner(.success(bambuddyQR))

        await model.scanQRCode(with: scanner)

        #expect(scanner.scans == 1)
        #expect(model.baseURL == "http://192.168.1.10:8000")
        #expect(model.apiKey == "bb_from_qr")
        #expect(model.qrStatus == .applied("Filled from the QR code."))
        // A read starts Test connection with what it filled in.
        #expect(model.connection == .ready)
    }

    @Test func aWrongQRCodeStartsNoTest() async {
        let model = makeModel()

        await model.scanQRCode(with: FakeQRScanner(.success("nonsense")))

        #expect(model.connection == nil)
    }

    @Test func aFailingScannerLeavesTheFieldsUntouched() async {
        let model = makeModel()

        await model.scanQRCode(with: FakeQRScanner(.failure(CameraFailed())))

        #expect(model.baseURL == "http://bambuddy.test:8000")
        #expect(model.apiKey == "bb_test")
        #expect(model.qrStatus == .failed("camera unavailable"))
        #expect(!model.hasChanges)
    }

    @Test func aCancelledScanChangesNothingAndShowsNoError() async {
        let model = makeModel()
        model.applyQRPayload("nonsense")
        #expect(model.qrStatus != nil)

        await model.scanQRCode(with: FakeQRScanner(.failure(CancellationError())))

        #expect(model.baseURL == "http://bambuddy.test:8000")
        #expect(model.apiKey == "bb_test")
        #expect(model.qrStatus == nil)
        #expect(!model.hasChanges)
    }

    // MARK: Test connection result

    @Test func anUntestedConnectionSaysSo() {
        let model = makeModel()
        #expect(model.connectionResult == StatusItem(text: "Not tested", symbol: .symbol("circle.dashed"), tint: .gray))
    }

    @Test(arguments: [
        (SettingsViewModel.Connection.testing, StatusItem(text: "Testing\u{2026}", symbol: .progress, tint: .gray)),
        (
            .ready,
            StatusItem(
                text: "Ready \u{00B7} inventory OK", symbol: .symbol("checkmark.circle.fill"), tint: .green
            )
        ),
        (
            .unreachable("no answer within 5 s"),
            StatusItem(
                text: "Unreachable: no answer within 5 s", symbol: .symbol("xmark.circle.fill"), tint: .red
            )
        ),
        (
            .failed("Bambuddy rejected the API key; check it in Settings"),
            StatusItem(
                text: "Bambuddy rejected the API key; check it in Settings", symbol: .symbol("xmark.circle.fill"),
                tint: .red
            )
        ),
    ])
    func eachTestResultHasItsPhraseSymbolAndTint(connection: SettingsViewModel.Connection, item: StatusItem) {
        #expect(SettingsViewModel.result(connection) == item)
    }

    @Test func aNetworkFailureIsUnreachableWithTheReason() async {
        let inventory = FakeInventory()
        inventory.spoolmanError = .network("no answer within 5 s")
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .unreachable("no answer within 5 s"))
        #expect(model.connectionResult.text == "Unreachable: no answer within 5 s")
        #expect(model.catalog.isEmpty)
    }

    @Test func aServerErrorFailsWithBambuddysAnswer() async {
        let inventory = FakeInventory()
        inventory.spoolmanError = .http(status: 500, message: "boom")
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .failed(BambuddyError.http(status: 500, message: "boom").localizedDescription))
        #expect(model.catalog.isEmpty)
    }

    @Test func aRejectedKeyFailsWithTheSessionsMessage() async {
        let inventory = FakeInventory()
        inventory.spoolmanError = .unauthorized
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .failed(BambuddyState.refused(.unauthorized).message!))
    }

    // MARK: Save row

    @Test func theSaveLineFollowsTheChanges() async {
        let model = makeModel()
        #expect(model.saveStatusText == "All changes saved")
        #expect(!model.canSave)
        #expect(!model.canRevert)

        model.apiKey = "bb_new"
        #expect(model.saveStatusText == "Unsaved changes")
        #expect(model.canSave)
        #expect(model.canRevert)

        #expect(await model.save())
        #expect(model.saveStatusText == "All changes saved")
        #expect(!model.canSave)
        #expect(!model.canRevert)
    }

    @Test func undoingAnEditByHandIsClean() {
        let model = makeModel()
        model.apiKey = "bb_new"
        model.apiKey = "bb_test"
        #expect(model.saveStatusText == "All changes saved")
    }

    @Test func revertRestoresTheSavedDraft() async {
        var settings = testSettings
        settings.port = "/dev/cu.usbmodemflip_A"
        let inventory = FakeInventory()
        inventory.catalogEntries = [
            CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250),
            CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180),
        ]
        let model = makeModel(inventory, settings: settings, apply: { _ in throw SecretStoreError.status(-25300) })
        await model.loadCatalog()
        model.baseURL = "http://10.0.0.5:8000"
        model.apiKey = "bb_new"
        model.catalogEntryId = 9
        model.coreWeight = 200
        model.defaultMode = .net
        model.transport = .bluetooth
        model.port = nil
        model.choosePeripheral(flipperA)
        await model.testConnection()
        #expect(!(await model.save()))

        model.revert()

        #expect(model.draft == settings)
        #expect(model.coreWeight == 250)
        #expect(!model.hasChanges)
        #expect(model.saveError == nil)
        #expect(model.connection == nil)
    }

    @Test func revertAfterASaveKeepsTheSavedValues() async {
        let model = makeModel()
        model.apiKey = "bb_saved"
        #expect(await model.save())
        model.apiKey = "bb_draft"

        model.revert()

        #expect(model.apiKey == "bb_saved")
        #expect(!model.hasChanges)
    }

    // MARK: Flipper section

    @Test(arguments: [
        (TransportKind?.some(.usb), "Connected over USB"),
        (.some(.bluetooth), "Connected over Bluetooth"),
        (nil, "No Flipper paired"),
    ])
    func theConnectionLineNamesTheLink(kind: TransportKind?, text: String) {
        #expect(SettingsViewModel.connectionLine(kind) == text)
        #expect(makeModel(connected: { kind }).connectionLine == text)
    }

    @Test func theBluetoothFlipperIsTheChosenOneOrTheSearch() async {
        let scan = ManualScan()
        let model = makeModel(scan: scan.start)
        #expect(model.bluetoothFlipperText == "First found")

        model.scanForFlippers()
        #expect(model.bluetoothFlipperText == "Searching\u{2026}")

        scan.continuation?.yield(flipperA)
        #expect(await eventually { model.discovered == [flipperA] })
        model.choosePeripheral(flipperA)
        #expect(model.bluetoothFlipperText == "Flipper Anmaa1")
    }

    @Test func forgetClearsTheChosenPortOverUSB() {
        var settings = testSettings
        settings.port = "/dev/cu.usbmodemflip_A"
        let model = makeModel(settings: settings)
        #expect(model.canForget)

        model.forget()

        #expect(model.port == nil)
        #expect(model.draft.transport == .usb)
        #expect(model.hasChanges)
        #expect(!model.canForget)
    }

    @Test func forgetClearsTheBluetoothFlipper() {
        var settings = testSettings
        settings.transport = .bluetooth
        settings.port = "/dev/cu.usbmodemflip_A"
        settings.peripheralId = flipperA.id
        settings.peripheralName = flipperA.name
        let model = makeModel(settings: settings)
        #expect(model.canForget)

        model.forget()

        #expect(model.peripheralId == nil)
        #expect(model.peripheralName == nil)
        #expect(model.port == "/dev/cu.usbmodemflip_A")
        #expect(!model.canForget)
    }

    @Test func nothingRememberedLeavesNothingToForget() {
        #expect(!makeModel().canForget)
    }
}

@MainActor
@Suite("SettingsViewModel: apply on change")
struct SettingsApplyOnChangeTests {
    /// Records every applied settings value.
    @MainActor
    final class Applied {
        var values: [Settings] = []
        var failure: (any Error)?

        func apply(_ settings: Settings) throws {
            if let failure { throw failure }
            values.append(settings)
        }
    }

    private func makeApplying(
        _ applied: Applied, inventory: FakeInventory = FakeInventory(), settings: Settings = testSettings
    ) -> SettingsViewModel {
        makeModel(inventory, settings: settings, appliesOnChange: true, apply: { try applied.apply($0) })
    }

    @Test func pickersApplyAtOnce() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.defaultMode = .net
        await model.settled()

        var expected = testSettings
        expected.defaultMode = .net
        #expect(applied.values == [expected])
        #expect(!model.hasChanges)
    }

    @Test func theTransportAndPortPickersApplyAtOnce() async {
        let applied = Applied()
        var settings = testSettings
        settings.transport = .usb
        let model = makeApplying(applied, settings: settings)

        model.transport = .bluetooth
        await model.settled()
        model.port = "/dev/cu.usbmodem1"
        await model.settled()
        model.port = "/dev/cu.usbmodem1"
        await model.settled()

        #expect(applied.values.map(\.transport) == [.bluetooth, .bluetooth])
        #expect(applied.values.map(\.port) == [nil, "/dev/cu.usbmodem1"])
    }

    @Test func clearingTheCatalogEntryAppliesItWithoutTouchingTheCoreWeight() async {
        let applied = Applied()
        var settings = testSettings
        settings.catalogEntryId = 9
        let model = makeApplying(applied, settings: settings)

        model.catalogEntryId = nil
        await model.settled()

        #expect(applied.values.map(\.catalogEntryId) == [nil])
        #expect(applied.values.map(\.coreWeight) == [settings.coreWeight])
    }

    @Test func choosingACatalogEntryAppliesTheEntryAndItsWeightOnce() async {
        let applied = Applied()
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180)]
        let model = makeApplying(applied, inventory: inventory)
        await model.loadCatalog()

        model.catalogEntryId = 9
        await model.settled()

        #expect(applied.values.map(\.catalogEntryId) == [9])
        #expect(applied.values.map(\.coreWeight) == [180])
    }

    @Test func textFieldsWaitForTheirCommit() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.baseURL = "http://10.0.0.5"
        model.baseURL = "http://10.0.0.5:8000"
        model.apiKey = "bb_new"
        model.coreWeight = 300
        await model.settled()
        #expect(applied.values.isEmpty)

        model.commit()
        await model.settled()

        var expected = testSettings
        expected.baseURL = "http://10.0.0.5:8000"
        expected.apiKey = "bb_new"
        expected.coreWeight = 300
        #expect(applied.values == [expected])
    }

    @Test func aPickerChangeLeavesAnUncommittedFieldAlone() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.baseURL = "http://10.0.0.5:80"
        model.defaultMode = .net
        await model.settled()

        #expect(applied.values.map(\.baseURL) == [testSettings.baseURL])
        #expect(applied.values.map(\.defaultMode) == [.net])
        #expect(model.baseURL == "http://10.0.0.5:80")
    }

    @Test func aCommitWithoutChangesAppliesNothing() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.commit()
        model.defaultMode = .gross
        await model.settled()

        #expect(applied.values.isEmpty)
    }

    @Test func anOutOfRangeCoreWeightIsNotAppliedButTheRestIs() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.coreWeight = 0
        model.apiKey = "bb_new"
        model.commit()
        await model.settled()

        #expect(applied.values.map(\.apiKey) == ["bb_new"])
        #expect(applied.values.map(\.coreWeight) == [testSettings.coreWeight])
        #expect(model.coreWeightError != nil)
    }

    @Test func changesApplyInOrderEachOnTheLastApplied() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.defaultMode = .net
        model.apiKey = "bb_new"
        model.commit()
        model.defaultMode = .gross
        await model.settled()

        #expect(applied.values.map(\.defaultMode) == [.net, .net, .gross])
        #expect(applied.values.map(\.apiKey) == ["bb_test", "bb_new", "bb_new"])
    }

    @Test func aFailedApplyIsReportedAndTheEditKept() async {
        let applied = Applied()
        applied.failure = SecretStoreError.status(-25300)
        let model = makeApplying(applied)

        model.apiKey = "bb_new"
        model.commit()
        await model.settled()

        #expect(model.saveError != nil)
        #expect(model.apiKey == "bb_new")

        applied.failure = nil
        model.commit()
        await model.settled()
        #expect(model.saveError == nil)
        #expect(applied.values.map(\.apiKey) == ["bb_new"])
    }

    @Test func choosingAFlipperAppliesIt() async {
        let applied = Applied()
        let model = makeApplying(applied)

        model.choosePeripheral(flipperA)
        await model.settled()

        #expect(applied.values.map(\.peripheralId) == [flipperA.id])
        #expect(applied.values.map(\.peripheralName) == [flipperA.name])
        #expect(applied.values.map(\.transport) == [.bluetooth])
    }

    @Test func forgettingTheFlipperAppliesIt() async {
        let applied = Applied()
        var settings = testSettings
        settings.transport = .bluetooth
        settings.peripheralId = flipperA.id
        settings.peripheralName = flipperA.name
        let model = makeApplying(applied, settings: settings)

        model.forget()
        await model.settled()

        #expect(applied.values.count == 1)
        #expect(applied.values.first?.peripheralId == nil)
        #expect(applied.values.first?.peripheralName == nil)
    }

    @Test func aQRCodeAppliesTheURLAndKeyAndTestsThem() async {
        let applied = Applied()
        let model = makeApplying(applied)

        await model.scanQRCode(with: FakeQRScanner(.success(bambuddyQR)))
        await model.settled()

        #expect(applied.values.map(\.baseURL) == ["http://192.168.1.10:8000"])
        #expect(applied.values.map(\.apiKey) == ["bb_from_qr"])
        #expect(model.connection == .ready)
        #expect(model.qrStatus == .applied("Filled from the QR code."))
    }

    @Test func withoutApplyOnChangeNothingAppliesUntilSave() async {
        var applied: [Settings] = []
        let model = makeModel(apply: { applied.append($0) })

        model.defaultMode = .net
        model.commit()
        await model.settled()
        #expect(applied.isEmpty)
        #expect(model.hasChanges)
    }

    @Test func theCoreWeightFieldTakesDigitsAsTyped() async {
        let applied = Applied()
        let model = makeApplying(applied)
        #expect(model.coreWeightText == "250")

        model.coreWeightText = "3x25"
        #expect(model.coreWeight == 325)
        model.coreWeightText = "012345"
        #expect(model.coreWeightText == "1234")
        model.coreWeightText = ""
        #expect(model.coreWeight == 0)
        #expect(model.coreWeightText == "")
        #expect(model.coreWeightError != nil)

        model.coreWeightText = "300"
        model.commit()
        await model.settled()
        #expect(applied.values.map(\.coreWeight) == [300])
    }

    /// Holds an apply until the test opens it.
    @MainActor
    final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func open() {
            isOpen = true
            waiting?.resume()
            waiting = nil
        }
    }

    private func changeThenDrop(_ applied: Applied, gate: Gate) {
        let model = makeModel(appliesOnChange: true, apply: { settings in
            if applied.values.isEmpty { await gate.wait() }
            try applied.apply(settings)
        })
        model.defaultMode = .net
        model.baseURL = "http://10.0.0.5:8000"
        model.commit()
    }

    @Test func aModelDroppedWhileApplyingStillAppliesItsQueuedChanges() async throws {
        let applied = Applied()
        let gate = Gate()

        changeThenDrop(applied, gate: gate)
        gate.open()
        for _ in 0..<200 where applied.values.count < 2 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(applied.values.map(\.defaultMode) == [.net, .net])
        #expect(applied.values.map(\.baseURL) == [testSettings.baseURL, "http://10.0.0.5:8000"])
    }

    // MARK: iPhone texts

    @Test(arguments: [
        (CameraAccess.authorized, SettingsViewModel.QRStatus?.none, "Scan the QR code Bambuddy shows when you create an API key.", StatusTint.gray),
        (.notDetermined, nil, "Scan the QR code Bambuddy shows when you create an API key.", .gray),
        (.authorized, .applied("Filled from the QR code."), "Filled from the QR code.", .green),
        (.authorized, .failed("Not a Bambuddy QR code"), "Not a Bambuddy QR code", .red),
        (.denied, nil, "Camera access is off. Allow it in Settings.", .gray),
        (.denied, .failed("x"), "Camera access is off. Allow it in Settings.", .gray),
        (.unsupported, nil, "This device has no camera. Type the URL and API key instead.", .gray),
        (.unsupported, .failed("x"), "This device has no camera. Type the URL and API key instead.", .gray),
    ])
    func theQRFooterFollowsTheCameraAndTheLastRead(
        camera: CameraAccess, status: SettingsViewModel.QRStatus?, text: String, tint: StatusTint
    ) {
        let footer = SettingsViewModel.qrFooter(camera: camera, status: status)
        #expect(footer.text == text)
        #expect(footer.tint == tint)
    }

    @Test func theCameraIsAskedForOnTheFirstScanAndADeniedOneOpensSettings() {
        // Not determined: Scan QR code asks; denied: Scan is dimmed and
        // Open Settings leads to the app's settings.
        #expect(CameraAccess.notDetermined.canScan)
        #expect(CameraAccess.authorized.canScan)
        #expect(!CameraAccess.denied.canScan)
        #expect(!CameraAccess.unsupported.canScan)
        #expect(CameraAccess.denied.offersOpenSettings)
        #expect(![CameraAccess.notDetermined, .authorized, .unsupported].contains { $0.offersOpenSettings })
    }

    @Test func theFlipperRowNamesTheFlipperAndItsState() async {
        let scan = ManualScan()
        let connected = LockedBox<TransportKind?>(nil)
        let model = makeModel(scan: scan.start, connected: { connected.value })
        #expect(model.flipperRowTitle == "No Flipper paired")
        #expect(model.flipperRowState.text == "Not connected")
        #expect(model.flipperRowState.symbol == .symbol("antenna.radiowaves.left.and.right.slash"))

        model.scanForFlippers()
        #expect(model.flipperRowState == StatusItem(text: "Searching\u{2026}", symbol: .progress, tint: .gray))

        scan.continuation?.yield(flipperA)
        #expect(await eventually { model.discovered == [flipperA] })
        model.choosePeripheral(flipperA)
        connected.mutate { $0 = .bluetooth }
        #expect(model.flipperRowTitle == "Flipper Anmaa1")
        #expect(
            model.flipperRowState
                == StatusItem(text: "Bluetooth", symbol: .symbol("antenna.radiowaves.left.and.right"), tint: .green)
        )
    }

    @Test func aFlipperConnectedWithoutAChoiceIsNamedGenerically() {
        let model = makeModel(connected: { .bluetooth })
        #expect(model.flipperRowTitle == "Flipper")
    }

    @Test func theFlipperFooterSaysBluetoothOnlyOnTheIPhone() {
        // iPhone page and iPad page, the Flipper section's footer.
        #expect(
            SettingsViewModel.flipperFooter(isPad: false)
                == "Bluetooth only on iPhone. The Flipper must be running FliBuddy."
        )
        #expect(SettingsViewModel.flipperFooter(isPad: true) == "The Flipper must be running FliBuddy.")
    }

    @Test func thePrivacyPolicyAndSupportLinksPointAtThePages() {
        #expect(AppLinks.privacyPolicy.absoluteString == "https://sokogen.github.io/flipperzero-flibuddy/privacy/")
        #expect(AppLinks.support.absoluteString == "https://sokogen.github.io/flipperzero-flibuddy/support/")
    }

    @Test func theVersionFooterNamesTheVersionAndTheBuild() {
        let full: [String: Any] = ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "42"]
        #expect(SettingsViewModel.versionFooter(info: full) == "FliBuddy 1.0 (42)")
        #expect(SettingsViewModel.versionFooter(info: ["CFBundleShortVersionString": "0.1.0"]) == "FliBuddy 0.1.0")
        #expect(SettingsViewModel.versionFooter(info: ["CFBundleVersion": "7"]) == "FliBuddy (7)")
        let blank: [String: Any] = ["CFBundleShortVersionString": " ", "CFBundleVersion": ""]
        #expect(SettingsViewModel.versionFooter(info: blank) == "FliBuddy")
        #expect(SettingsViewModel.versionFooter(info: nil) == "FliBuddy")
    }

    @Test func openingSettingsLoadsTheCatalogEachTime() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250)]
        let model = makeModel(inventory)
        #expect(model.catalog.isEmpty)

        await model.opened()
        #expect(model.catalog.map(\.id) == [3])

        // Edited in Bambuddy while Settings was away: the next visit shows it.
        inventory.catalogEntries.append(CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180))
        await model.opened()
        #expect(model.catalog.map(\.id) == [3, 9])
        #expect(model.catalogError == nil)
    }

    @Test func leavingSettingsCommitsTheFieldAndStopsTheScan() async {
        let scan = ManualScan()
        let applied = LockedBox<[Settings]>([])
        let model = makeModel(
            scan: scan.start, appliesOnChange: true, apply: { settings in applied.mutate { $0.append(settings) } }
        )
        model.scanForFlippers()
        model.baseURL = "http://10.0.0.5:8000"

        model.left()
        await model.settled()

        #expect(!model.isScanning)
        #expect(await eventually { scan.stopped.value })
        #expect(applied.value.map(\.baseURL) == ["http://10.0.0.5:8000"])
    }

    @Test(arguments: [
        Settings(baseURL: "", apiKey: "bb_test"),
        Settings(baseURL: "https://bambuddy.example.com", apiKey: ""),
        Settings(baseURL: "http://bambuddy.example.com", apiKey: "bb_test"),
    ])
    func openingSettingsWithoutAServerAndKeySkipsTheCatalog(settings: Settings) async {
        // Every visit of a fresh install would show a red catalog error.
        let inventory = FakeInventory()
        let model = makeModel(inventory, settings: settings, requiresHTTPS: true)

        await model.opened()

        #expect(model.catalogError == nil)
        #expect(!inventory.calls.contains(.catalog))
    }

    @Test func openingSettingsShowsWhyTheCatalogDidNotLoad() async {
        let inventory = FakeInventory()
        inventory.catalogError = .network("no answer within 5 s")
        let model = makeModel(inventory)

        await model.opened()

        #expect(model.catalog.isEmpty)
        #expect(model.catalogError != nil)
    }
}

@MainActor
@Suite("SettingsViewModel: log")
struct SettingsViewModelLogTests {
    @Test func aGoodTestIsLoggedFromStartToResultWithoutTheKey() async {
        var settings = testSettings
        settings.apiKey = "secret-key-123"
        let model = makeModel(settings: settings)

        let sink = await capturingLog { await model.testConnection() }

        #expect(sink.events == [
            "settings test connection: url=http://bambuddy.test:8000",
            "settings catalog: entries=1",
            "settings test connection: ready",
        ])
        #expect(!sink.lines.contains { $0.message.contains("secret-key-123") })
    }

    @Test func anUnreachableBambuddyIsLoggedAsAnError() async {
        let inventory = FakeInventory()
        inventory.spoolmanError = .network("no answer within 5 s")
        let model = makeModel(inventory)

        let sink = await capturingLog { await model.testConnection() }

        let results = sink.lines.filter { $0.message.hasPrefix("test connection: unreachable") }
        #expect(results.map(\.message) == ["test connection: unreachable reason=no answer within 5 s"])
        #expect(results.map(\.level) == [.error])
    }

    @Test func aRefusingBambuddyOrMissingClientIsLoggedAsFailed() async {
        let inventory = FakeInventory()
        inventory.spoolman = true
        let refusing = makeModel(inventory)
        let clientless = makeModel(nil)

        let sink = await capturingLog {
            await refusing.testConnection()
            await clientless.testConnection()
        }

        #expect(sink.events("settings test connection: failed") == [
            "settings test connection: failed message=Bambuddy is in Spoolman mode; FliBuddy supports internal inventory only",
            "settings test connection: failed message=no client",
        ])
    }

    @Test func aTestOfEditedSettingsIsDroppedAtDebug() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)
        inventory.onSpoolman = { @MainActor in model.baseURL = "http://10.0.0.5:8000" }

        let sink = await capturingLog(level: .debug) { await model.testConnection() }

        #expect(sink.events("settings test connection") == [
            "settings test connection: url=http://bambuddy.test:8000",
            "settings test connection: dropped, the URL or API key was edited",
        ])
    }

    @Test func catalogLoadsAreLoggedWithTheirOutcome() async {
        let inventory = FakeInventory()
        let model = makeModel(inventory)

        let sink = await capturingLog {
            await model.loadCatalog()
            inventory.catalogError = .http(status: 500, message: "boom")
            await model.loadCatalog()
            await makeModel(nil).loadCatalog()
        }

        #expect(sink.events == [
            "settings catalog: entries=1",
            "settings catalog failed: error=Bambuddy HTTP 500: boom",
            "settings catalog failed: error=no client",
        ])
        #expect(sink.lines.map(\.level) == [.info, .error, .error])
    }
}

@MainActor
@Suite("SettingsViewModel: HTTPS only")
struct HTTPSOnlySettingsTests {
    private static let message = "FliBuddy needs an https:// address."

    @Test func anHTTPURLHasTheMessageAndAnHTTPSOneDoesNot() {
        let model = makeModel(requiresHTTPS: true)
        #expect(model.urlError == Self.message)
        model.baseURL = "https://bambuddy.example.com"
        #expect(model.urlError == nil)
        model.baseURL = "  HTTP://bambuddy.example.com "
        #expect(model.urlError == Self.message)
        model.baseURL = ""
        #expect(model.urlError == nil)
    }

    @Test func theMacKeepsHTTP() {
        let model = makeModel(requiresHTTPS: false)
        #expect(model.urlError == nil)
    }

    @Test func saveRefusesAnHTTPURL() async {
        let applied = LockedBox<[Settings]>([])
        let model = makeModel(requiresHTTPS: true, apply: { settings in applied.mutate { $0.append(settings) } })

        let saved = await model.save()

        #expect(!saved)
        #expect(model.saveError == Self.message)
        #expect(applied.value.isEmpty)
    }

    @Test func aCommitAppliesTheKeyButNotAnHTTPURL() async {
        let applied = LockedBox<[Settings]>([])
        var start = testSettings
        start.baseURL = "https://old.example.com"
        let model = makeModel(
            settings: start, appliesOnChange: true, requiresHTTPS: true,
            apply: { settings in applied.mutate { $0.append(settings) } }
        )

        model.baseURL = "http://192.168.1.20:8000"
        model.apiKey = "bb_new"
        model.commit()
        await model.settled()

        #expect(applied.value.map(\.baseURL) == ["https://old.example.com"])
        #expect(applied.value.map(\.apiKey) == ["bb_new"])
        #expect(model.urlError == Self.message)
    }

    @Test func aQRCodeWithAnHTTPURLStillFillsTheKeyAndTheFieldShowsTheError() async {
        let applied = LockedBox<[Settings]>([])
        let model = makeModel(
            settings: Settings(baseURL: "https://old.example.com"), appliesOnChange: true, requiresHTTPS: true,
            apply: { settings in applied.mutate { $0.append(settings) } }
        )

        model.applyQRPayload(bambuddyQR)
        await model.settled()

        #expect(model.apiKey == "bb_from_qr")
        #expect(model.baseURL == "http://192.168.1.10:8000")
        #expect(model.urlError == Self.message)
        #expect(applied.value.map(\.apiKey) == ["bb_from_qr"])
        #expect(applied.value.map(\.baseURL) == ["https://old.example.com"])
    }

    @Test func testConnectionNamesTheProblem() async {
        // The real client factory refuses the address.
        let model = SettingsViewModel(
            settings: testSettings, makeInventory: { try $0.makeClient(requireHTTPS: true) }, requiresHTTPS: true, apply: { _ in }
        )

        await model.testConnection()

        #expect(model.connection == .failed("Needs HTTPS"))
        #expect(model.connectionResult.text == "Needs HTTPS")
    }

    @Test func anUntrustedCertificateIsItsOwnTestResult() async {
        let inventory = FakeInventory()
        inventory.spoolmanError = .untrustedCertificate
        let model = makeModel(inventory)

        await model.testConnection()

        #expect(model.connection == .failed("Certificate not trusted"))
    }

    @Test func aQRCodeWithAnHTTPURLSaysTheKeyWasFilledAndTestsNothing() async {
        let inventory = FakeInventory()
        let model = makeModel(
            inventory, settings: Settings(baseURL: "https://old.example.com"), appliesOnChange: true,
            requiresHTTPS: true
        )
        let sink = await capturingLog {
            await model.scanQRCode(with: FakeQRScanner(.success(bambuddyQR)))
            await model.settled()
        }

        #expect(
            model.qrStatus == .failed("Filled in the API key. The QR code has an http:// address; FliBuddy needs https://.")
        )
        #expect(model.connection == nil)
        #expect(!inventory.calls.contains(.spoolman))
        #expect(sink.events("settings qr: http address refused") == ["settings qr: http address refused, key filled"])
    }

    @Test func aCommittedHTTPURLIsLoggedWithoutTheAddress() async {
        let model = makeModel(appliesOnChange: true, requiresHTTPS: true)
        model.baseURL = "http://192.168.1.20:8000"
        let sink = await capturingLog {
            model.commit()
            await model.settled()
        }
        #expect(sink.events("settings commit: http address refused") == ["settings commit: http address refused"])
    }
}
