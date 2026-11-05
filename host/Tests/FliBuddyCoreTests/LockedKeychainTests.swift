import Foundation
import Security
import Testing
@testable import FliBuddyCore

/// A Keychain whose reads fail with "User interaction is not allowed"
/// (-25308) while it is locked, and that records every write and delete.
final class LockableSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var isLocked: Bool
    private var recorded: [String?] = []

    init(locked: Bool = false, key: String? = nil) {
        isLocked = locked
        values[SettingsStore.apiKeyAccount] = key
    }

    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }

    /// The values passed to `setSecret`, `nil` for a delete.
    var writes: [String?] { lock.withLock { recorded } }

    func secret(for account: String) throws -> String? {
        try lock.withLock {
            if isLocked { throw SecretStoreError.status(-25308) }
            return values[account]
        }
    }

    func setSecret(_ value: String?, for account: String) throws {
        lock.withLock {
            recorded.append(value)
            values[account] = value
        }
    }

    var stored: String? { lock.withLock { values[SettingsStore.apiKeyAccount] } }
}

@Suite("API key while the Keychain is locked")
struct LockedKeychainSettingsTests {
    private func makeStore(_ secrets: LockableSecretStore) -> SettingsStore {
        SettingsStore(defaults: InMemoryKeyValueStore(), secrets: secrets)
    }

    @Test func aReadErrorLoadsAsAnUnknownKey() {
        let store = makeStore(LockableSecretStore(locked: true, key: "bb_real"))

        let settings = store.load()

        #expect(settings.apiKey == "")
        #expect(settings.apiKeyUnknown)
    }

    @Test func aReadableKeyIsKnown() {
        let settings = makeStore(LockableSecretStore(key: "bb_real")).load()
        #expect(settings.apiKey == "bb_real")
        #expect(!settings.apiKeyUnknown)
        #expect(!makeStore(LockableSecretStore()).load().apiKeyUnknown)
    }

    @Test func savingAnUnrelatedChangeLeavesTheKeyAlone() throws {
        let secrets = LockableSecretStore(locked: true, key: "bb_real")
        let store = makeStore(secrets)
        var settings = store.load()

        settings.coreWeight = 300
        try store.save(settings)

        #expect(secrets.writes.isEmpty)
        secrets.locked = false
        let reloaded = store.load()
        #expect(reloaded.apiKey == "bb_real")
        #expect(reloaded.coreWeight == 300)
    }

    @Test func aNewKeyTypedOverAnUnknownOneIsSaved() throws {
        let secrets = LockableSecretStore(locked: true, key: "bb_real")
        let store = makeStore(secrets)
        var settings = store.load()

        settings.apiKey = "bb_new"
        try store.save(settings)

        #expect(!settings.apiKeyUnknown)
        #expect(secrets.writes == ["bb_new"])
    }

    @Test func settingTheSameEmptyKeyKeepsItUnknown() {
        var settings = makeStore(LockableSecretStore(locked: true)).load()
        settings.apiKey = ""
        #expect(settings.apiKeyUnknown)
    }

    @Test func clearingAKnownKeyStillDeletesIt() throws {
        let secrets = LockableSecretStore(key: "bb_real")
        let store = makeStore(secrets)
        var settings = store.load()

        settings.apiKey = ""
        try store.save(settings)

        #expect(secrets.writes == [nil])
        #expect(secrets.stored == nil)
    }

    @Test func theLogSaysUnknownNotAbsentAndNeverShowsTheKey() async throws {
        let store = makeStore(LockableSecretStore(locked: true, key: "bb_real"))

        let sink = await capturingLog {
            var settings = store.load()
            settings.coreWeight = 300
            try? store.save(settings)
        }

        #expect(sink.events("settings load").first?.contains("key=unknown") == true)
        #expect(sink.events("settings save").first?.contains("key=unknown") == true)
        #expect(sink.lines.contains { $0.message.hasPrefix("keychain read failed: status=-25308") })
        #expect(!sink.lines.contains { $0.message.contains("bb_real") })
    }

    @Test func newKeychainItemsAreReadableAfterTheFirstUnlock() {
        let attributes = KeychainSecretStore(service: "S").newItem("bb_key", for: "acct")
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrService as String] as? String == "S")
        #expect(attributes[kSecAttrAccount as String] as? String == "acct")
        #expect(attributes[kSecValueData as String] as? Data == Data("bb_key".utf8))
    }

    @Test func theMigrationUpdatesOnlyItemsStillWhenUnlocked() {
        let (match, update) = KeychainSecretStore(service: "S").accessibilityMigration(for: "acct")
        #expect(match[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        #expect(match[kSecAttrAccount as String] as? String == "acct")
        #expect(update[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(update.count == 1)
    }
}

@MainActor
@Suite("HostModel while the Keychain is locked")
struct LockedKeychainHostModelTests {
    private func makeModel(
        _ secrets: LockableSecretStore, inventory: FakeInventory = FakeInventory()
    ) throws -> (HostModel, SettingsStore) {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: secrets)
        secrets.locked = false
        try store.save(testSettings)
        secrets.locked = true
        let model = HostModel(
            store: store, makeInventory: { _ in inventory }, makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }
        )
        return (model, store)
    }

    @Test func anUnrelatedChangeKeepsTheKeyAndTheWatchIsNotToldItIsGone() async throws {
        let secrets = LockableSecretStore(key: "bb_test")
        let (model, _) = try makeModel(secrets)
        let before = secrets.writes.count
        let sent = LockedBox<[Settings]>([])
        model.onSettingsSaved = { settings in sent.mutate { $0.append(settings) } }
        #expect(model.settings.apiKeyUnknown)

        var new = model.settings
        new.coreWeight = 300
        try await model.apply(new)

        #expect(secrets.writes.count == before)
        #expect(secrets.stored == "bb_test")
        #expect(sent.value.map(\.apiKeyUnknown) == [true])
    }

    @Test func reloadingAfterTheUnlockRestoresTheKeyAndReconfiguresTheSession() async throws {
        let secrets = LockableSecretStore(key: "bb_test")
        let (model, _) = try makeModel(secrets)
        var changed = model.settings
        changed.coreWeight = 300
        try await model.apply(changed)
        let sent = LockedBox<[Settings]>([])
        model.onSettingsSaved = { settings in sent.mutate { $0.append(settings) } }

        secrets.locked = false
        await model.reloadSettings()

        #expect(model.settings.apiKey == "bb_test")
        #expect(!model.settings.apiKeyUnknown)
        // What was changed meanwhile stays.
        #expect(model.settings.coreWeight == 300)
        #expect(model.feed.settings == model.settings)
        #expect(await model.session.settings == model.settings)
        #expect(await model.session.bambuddy == .ready)
        #expect(sent.value == [model.settings])
    }

    @Test func reloadingWhileStillLockedChangesNothing() async throws {
        let (model, _) = try makeModel(LockableSecretStore(key: "bb_test"))
        let before = model.settings

        await model.reloadSettings()

        #expect(model.settings == before)
        #expect(model.settings.apiKeyUnknown)
    }

    @Test func reloadingWithAKnownKeyReadsNothing() async throws {
        let secrets = LockableSecretStore(key: "bb_test")
        let (model, _) = try makeModel(secrets)
        secrets.locked = false
        await model.reloadSettings()
        secrets.locked = true

        await model.reloadSettings()

        #expect(model.settings.apiKey == "bb_test")
        #expect(!model.settings.apiKeyUnknown)
    }

    @Test func aStaleScreenCannotPutTheUnknownKeyBack() async throws {
        let secrets = LockableSecretStore(key: "bb_test")
        let (model, _) = try makeModel(secrets)
        let stale = model.settings
        secrets.locked = false
        await model.reloadSettings()

        var change = stale
        change.coreWeight = 310
        try await model.apply(change)

        #expect(model.settings.apiKey == "bb_test")
        #expect(!model.settings.apiKeyUnknown)
        #expect(model.settings.coreWeight == 310)
        #expect(secrets.stored == "bb_test")
    }

    @Test func aKeyTypedWhileLockedReplacesTheUnknownOne() async throws {
        let secrets = LockableSecretStore(key: "bb_test")
        let (model, _) = try makeModel(secrets)

        var new = model.settings
        new.apiKey = "bb_typed"
        try await model.apply(new)
        secrets.locked = false
        await model.reloadSettings()

        #expect(secrets.stored == "bb_typed")
        #expect(model.settings.apiKey == "bb_typed")
    }
}

@MainActor
@Suite("SettingsViewModel with an unknown key")
struct UnknownKeySettingsViewModelTests {
    private var unknown: Settings {
        var settings = testSettings
        settings.apiKey = ""
        settings.apiKeyUnknown = true
        return settings
    }

    private func makeModel(_ settings: Settings, applied: LockedBox<[Settings]>) -> SettingsViewModel {
        SettingsViewModel(
            settings: settings, makeInventory: { _ in FakeInventory() }, discoverPorts: { [] },
            appliesOnChange: true, apply: { new in applied.mutate { $0.append(new) } }
        )
    }

    @Test func anUnrelatedChangeIsAppliedWithTheKeyStillUnknown() async {
        let applied = LockedBox<[Settings]>([])
        let model = makeModel(unknown, applied: applied)

        model.defaultMode = .net
        await model.settled()

        #expect(applied.value.map(\.apiKeyUnknown) == [true])
        #expect(model.draft.apiKeyUnknown)
    }

    @Test func committingTheUntouchedKeyFieldKeepsItUnknown() async {
        let applied = LockedBox<[Settings]>([])
        let model = makeModel(unknown, applied: applied)

        model.commit()
        await model.settled()

        #expect(applied.value.isEmpty)
        #expect(model.draft.apiKeyUnknown)
    }

    @Test func aTypedKeyIsKnownAndApplied() async {
        let applied = LockedBox<[Settings]>([])
        let model = makeModel(unknown, applied: applied)

        model.apiKey = "bb_typed"
        model.commit()
        await model.settled()

        #expect(applied.value.map(\.apiKey) == ["bb_typed"])
        #expect(applied.value.map(\.apiKeyUnknown) == [false])
    }

    @Test func aRestoredKeyFillsTheUntouchedField() {
        let model = makeModel(unknown, applied: LockedBox([]))

        model.adoptRestoredAPIKey(testSettings)

        #expect(model.apiKey == "bb_test")
        #expect(!model.draft.apiKeyUnknown)
        #expect(!model.hasChanges)
    }

    @Test func aRestoredKeyDoesNotReplaceOneBeingTyped() {
        let model = makeModel(unknown, applied: LockedBox([]))
        model.apiKey = "bb_typ"

        model.adoptRestoredAPIKey(testSettings)

        #expect(model.apiKey == "bb_typ")
    }
}
