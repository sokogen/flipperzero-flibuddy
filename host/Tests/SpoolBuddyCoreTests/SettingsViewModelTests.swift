import Foundation
import Testing
@testable import SpoolBuddyCore

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
        scanDuration: scanDuration,
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

        #expect(model.connection == .ok("Connected; internal inventory"))
        #expect(model.catalog.map(\.id) == [3, 9])
        #expect(inventory.calls.contains(.spoolman))
        #expect(inventory.colorMapLoads == 0)
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
        settings.coreWeight = 325
        let model = makeModel(inventory, settings: settings)

        await model.loadCatalog()

        #expect(model.draft.coreWeight == 325)
        #expect(!model.hasChanges)
    }

    @Test func editingAfterPickingAnEntryKeepsTheEdit() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180)]
        var applied: [Settings] = []
        let model = makeModel(inventory, apply: { applied.append($0) })
        await model.loadCatalog()

        model.catalogEntryId = 9
        model.coreWeight = 325

        #expect(await model.save())
        #expect(applied.map(\.coreWeight) == [325])
        #expect(applied.map(\.catalogEntryId) == [9])
    }

    @Test func reselectingTheSameEntryKeepsTheEdit() async {
        let inventory = FakeInventory()
        inventory.catalogEntries = [CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250)]
        let model = makeModel(inventory)
        await model.loadCatalog()

        model.coreWeight = 325
        model.catalogEntryId = 3

        #expect(model.draft.coreWeight == 325)
    }

    @Test func anEditedCoreWeightIsSavedWithoutACatalog() async {
        var applied: [Settings] = []
        let model = makeModel(apply: { applied.append($0) })

        model.coreWeight = 325

        #expect(model.hasChanges)
        #expect(await model.save())
        #expect(applied.map(\.coreWeight) == [325])
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

    @Test(arguments: [1, 325, 5000])
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

        model.forgetPeripheral()

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
        #expect(model.connection == .ok("Connected; internal inventory"))

        model.applyQRPayload(bambuddyQR)

        #expect(model.baseURL == "http://192.168.1.10:8000")
        #expect(model.apiKey == "bb_from_qr")
        #expect(model.qrStatus == .applied("URL and API key read from the QR code; Save to keep them"))
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
        #expect(model.qrStatus == .applied("URL and API key read from the QR code; Save to keep them"))
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
}
