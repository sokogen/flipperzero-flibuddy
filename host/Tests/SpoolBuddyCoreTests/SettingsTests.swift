import Foundation
import Testing
@testable import SpoolBuddyCore

/// A `UserDefaults` suite private to one test, removed when the test ends.
final class ScratchDefaults {
    let name = "spoolbuddy-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit { defaults.removePersistentDomain(forName: name) }
}

@Suite struct SettingsTests {
    @Test func defaultsMatchTheDesign() {
        let settings = Settings()
        #expect(settings.baseURL == "")
        #expect(settings.apiKey == "")
        #expect(settings.catalogEntryId == nil)
        #expect(settings.coreWeight == 250)
        #expect(settings.defaultMode == .gross)
        #expect(settings.port == nil)
        #expect(!settings.isConfigured)
    }

    @Test func aStoreWithNothingSavedLoadsTheDefaults() {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        #expect(store.load() == Settings())
    }

    @Test func savedSettingsLoadBack() throws {
        let scratch = ScratchDefaults()
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: scratch.defaults, secrets: secrets)

        try store.save(testSettings)

        #expect(store.load() == testSettings)
        #expect(SettingsStore(defaults: scratch.defaults, secrets: secrets).load() == testSettings)
    }

    @Test func theAPIKeyGoesToTheSecretStoreOnly() throws {
        let scratch = ScratchDefaults()
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: scratch.defaults, secrets: secrets)

        try store.save(testSettings)

        #expect(try secrets.secret(for: SettingsStore.apiKeyAccount) == "bb_test")
        let plist = scratch.defaults.dictionaryRepresentation()
        #expect(!plist.values.contains { ($0 as? String) == "bb_test" })
    }

    @Test func anEmptyAPIKeyDeletesTheSecret() throws {
        let scratch = ScratchDefaults()
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: scratch.defaults, secrets: secrets)
        try store.save(testSettings)

        var cleared = testSettings
        cleared.apiKey = ""
        try store.save(cleared)

        #expect(try secrets.secret(for: SettingsStore.apiKeyAccount) == nil)
        #expect(store.load().apiKey == "")
    }

    @Test func aChosenPortLoadsBackAndClears() throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        var settings = testSettings
        settings.port = "/dev/cu.usbmodemflip_Anmaa1"
        try store.save(settings)
        #expect(store.load().port == "/dev/cu.usbmodemflip_Anmaa1")
        settings.port = nil
        try store.save(settings)
        #expect(store.load().port == nil)
    }

    @Test func aClearedCatalogEntryLoadsAsNil() throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        try store.save(testSettings)
        var cleared = testSettings
        cleared.catalogEntryId = nil
        try store.save(cleared)
        #expect(store.load().catalogEntryId == nil)
    }

    @Test func aFailingSecretStoreSurfaces() {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: FailingSecretStore())
        #expect(throws: SecretStoreError.status(-25300)) { try store.save(testSettings) }
        #expect(store.load().apiKey == "")
    }

    @Test func choosingACatalogEntrySetsItsIdAndWeight() {
        var settings = Settings()
        settings.useCatalogEntry(CatalogEntry(id: 9, name: "Bambu Lab - Cardboard", weight: 180))
        #expect(settings.catalogEntryId == 9)
        #expect(settings.coreWeight == 180)
    }

    @Test func configuredNeedsAnHTTPURLAndAKey() {
        #expect(testSettings.isConfigured)
        var noKey = testSettings
        noKey.apiKey = "  "
        #expect(!noKey.isConfigured)
        var badURL = testSettings
        badURL.baseURL = "bambuddy.local"
        #expect(!badURL.isConfigured)
    }

    @Test func makeClientBuildsAClientForTheBaseURL() throws {
        var settings = testSettings
        settings.baseURL = "  http://bambuddy.test:8000/  "
        let client = try settings.makeClient()
        #expect(client.baseURL.absoluteString == "http://bambuddy.test:8000/")
    }

    @Test func makeClientRefusesIncompleteSettings() {
        #expect(throws: BambuddyError.invalidBaseURL("ftp://x")) {
            var settings = testSettings
            settings.baseURL = "ftp://x"
            _ = try settings.makeClient()
        }
        #expect(throws: SettingsError.missingAPIKey) {
            var settings = testSettings
            settings.apiKey = ""
            _ = try settings.makeClient()
        }
    }

    @Test func inMemorySecretsRoundTrip() throws {
        let secrets = InMemorySecretStore()
        #expect(try secrets.secret(for: "a") == nil)
        try secrets.setSecret("x", for: "a")
        #expect(try secrets.secret(for: "a") == "x")
        try secrets.setSecret(nil, for: "a")
        #expect(try secrets.secret(for: "a") == nil)
    }
}

private struct FailingSecretStore: SecretStore {
    func secret(for account: String) throws -> String? { throw SecretStoreError.status(-25300) }
    func setSecret(_ value: String?, for account: String) throws { throw SecretStoreError.status(-25300) }
}
