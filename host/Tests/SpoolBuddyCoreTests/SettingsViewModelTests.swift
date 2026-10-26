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
    apply: @escaping @MainActor (Settings) async throws -> Void = { _ in }
) -> SettingsViewModel {
    SettingsViewModel(
        settings: settings,
        makeInventory: { _ in
            guard let inventory else { throw NoClient() }
            return inventory
        },
        discoverPorts: { ports },
        apply: apply
    )
}

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

    @Test func aFailedCatalogLoadIsReported() async {
        let inventory = FakeInventory()
        inventory.catalogError = .unauthorized
        let model = makeModel(inventory)

        await model.loadCatalog()

        #expect(model.catalog.isEmpty)
        #expect(model.catalogError == BambuddyError.unauthorized.localizedDescription)
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
}
