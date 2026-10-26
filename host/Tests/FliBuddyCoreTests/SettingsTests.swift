import Foundation
import Testing
@testable import FliBuddyCore

/// A `UserDefaults` suite private to one test, removed when the test ends.
final class ScratchDefaults {
    let name = "flibuddy-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        // `removePersistentDomain` empties the suite but leaves its plist in
        // ~/Library/Preferences; delete the file too so test runs leave no
        // litter behind.
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
        let plist = URL.homeDirectory.appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}

@Suite struct SettingsTests {
    @Test func defaultsMatchTheDesign() {
        let settings = Settings()
        #expect(settings.baseURL == "")
        #expect(settings.apiKey == "")
        #expect(settings.catalogEntryId == nil)
        #expect(settings.coreWeight == 325)
        #expect(settings.defaultMode == .gross)
        #expect(settings.port == nil)
        #expect(settings.peripheralId == nil)
        #expect(settings.peripheralName == nil)
        #expect(!settings.isConfigured)
    }

    @Test func theDefaultTransportDependsOnThePlatform() {
        #if os(macOS)
        #expect(TransportKind.platformDefault == .usb)
        #expect(TransportKind.available == [.usb, .bluetooth])
        #else
        #expect(TransportKind.platformDefault == .bluetooth)
        #expect(TransportKind.available == [.bluetooth])
        #endif
        #expect(Settings().transport == TransportKind.platformDefault)
    }

    @Test func theTransportChoiceFollowsTheKind() {
        let id = UUID()
        var settings = Settings(transport: .usb, port: "/dev/cu.usbmodemflip_A", peripheralId: id, peripheralName: "Flipper A")
        #expect(settings.transportChoice == .usb(port: "/dev/cu.usbmodemflip_A"))
        settings.transport = .bluetooth
        #expect(settings.transportChoice == .bluetooth(peripheral: id))
        settings.peripheralId = nil
        #expect(settings.transportChoice == .bluetooth(peripheral: nil))
    }

    @Test func theTransportAndPeripheralLoadBackAndClear() throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        var settings = testSettings
        settings.transport = .bluetooth
        settings.peripheralId = UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")
        settings.peripheralName = "Flipper Anmaa1"
        try store.save(settings)
        #expect(store.load() == settings)

        settings.transport = .usb
        settings.peripheralId = nil
        settings.peripheralName = nil
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func anUnknownTransportLoadsAsThePlatformDefault() {
        let scratch = ScratchDefaults()
        scratch.defaults.set("carrier-pigeon", forKey: "flipper.transport")
        scratch.defaults.set("not-a-uuid", forKey: "flipper.peripheralId")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        #expect(store.load().transport == TransportKind.platformDefault)
        #expect(store.load().peripheralId == nil)
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

    @Test func anEditedCoreWeightLoadsBack() throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        var settings = testSettings
        settings.coreWeight = 412

        try store.save(settings)

        #expect(store.load().coreWeight == 412)
        #expect(store.load().catalogEntryId == 3)
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

    @Test func missingAPIKeyIsExplained() {
        #expect(SettingsError.missingAPIKey.localizedDescription.contains("API key"))
    }

    @Test func keychainServiceIsNamedAfterTheApp() {
        #expect(KeychainSecretStore.defaultService == "FliBuddy")
        #expect(KeychainSecretStore().service == "FliBuddy")
    }

    /// Uses the real login Keychain under a throwaway service. Skipped where the
    /// process cannot write to a Keychain at all (some sandboxes, headless CI).
    @Test(.enabled(if: keychainIsWritable(), "no writable Keychain"))
    func keychainSecretsRoundTrip() throws {
        let store = KeychainSecretStore(service: "FliBuddyTests-\(UUID().uuidString)")
        defer { try? store.setSecret(nil, for: "key") }
        #expect(try store.secret(for: "key") == nil)
        try store.setSecret("bb_one", for: "key")
        #expect(try store.secret(for: "key") == "bb_one")
        try store.setSecret("bb_two", for: "key")
        #expect(try store.secret(for: "key") == "bb_two")
        try store.setSecret(nil, for: "key")
        #expect(try store.secret(for: "key") == nil)
        try store.setSecret(nil, for: "key")
    }
}

private func keychainIsWritable() -> Bool {
    let probe = KeychainSecretStore(service: "FliBuddyTests-probe-\(UUID().uuidString)")
    guard (try? probe.setSecret("probe", for: "probe")) != nil else { return false }
    try? probe.setSecret(nil, for: "probe")
    return true
}

struct FailingSecretStore: SecretStore {
    func secret(for account: String) throws -> String? { throw SecretStoreError.status(-25300) }
    func setSecret(_ value: String?, for account: String) throws { throw SecretStoreError.status(-25300) }
}
