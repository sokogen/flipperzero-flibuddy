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
    /// Settings stored by an earlier launch (they hold the layout version),
    /// readable: the Keychain is locked after the first unlock, its item
    /// still `WhenUnlocked` from before 1.0.
    private func makeStore(_ secrets: LockableSecretStore) -> SettingsStore {
        let defaults = InMemoryKeyValueStore()
        defaults.set(SettingsStore.currentVersion, forKey: "settings.version")
        return SettingsStore(defaults: defaults, secrets: secrets)
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

        model.adoptRestoredSettings(testSettings)

        #expect(model.apiKey == "bb_test")
        #expect(!model.draft.apiKeyUnknown)
        #expect(!model.hasChanges)
    }

    @Test func aRestoredKeyDoesNotReplaceOneBeingTyped() {
        let model = makeModel(unknown, applied: LockedBox([]))
        model.apiKey = "bb_typ"

        model.adoptRestoredSettings(testSettings)

        #expect(model.apiKey == "bb_typ")
    }
}

/// `UserDefaults` before the first unlock since the device started: its
/// file cannot be read, so every key reads as missing. Records the writes
/// made while locked (they would not reach the file either) and drops them.
final class LockableKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private let backing = InMemoryKeyValueStore()
    private var isLocked = false
    private var recorded: [String] = []

    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }

    /// The keys set or removed while locked.
    var lockedWrites: [String] { lock.withLock { recorded } }

    func string(forKey key: String) -> String? {
        locked ? nil : backing.string(forKey: key)
    }

    func object(forKey key: String) -> Any? {
        locked ? nil : backing.object(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        if locked { return lock.withLock { recorded.append(key) } }
        backing.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        if locked { return lock.withLock { recorded.append(key) } }
        backing.removeObject(forKey: key)
    }
}

/// The Keychain item and the stored settings after a restart, before the
/// first unlock: the Keychain answers -25308 and `UserDefaults` reads empty.
struct BeforeFirstUnlock {
    let defaults = LockableKeyValueStore()
    let secrets = LockableSecretStore()
    var store: SettingsStore { SettingsStore(defaults: defaults, secrets: secrets) }

    /// `settings` saved while unlocked, then the device restarts.
    init(saved settings: Settings) throws {
        try SettingsStore(defaults: defaults, secrets: secrets).save(settings)
        locked = true
    }

    var locked: Bool {
        get { secrets.locked }
        nonmutating set {
            secrets.locked = newValue
            defaults.locked = newValue
        }
    }
}

@Suite("Settings before the first unlock")
struct BeforeFirstUnlockSettingsTests {
    private var saved: Settings {
        var settings = testSettings
        settings.coreWeight = 300
        settings.transport = .bluetooth
        settings.peripheralId = UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")
        settings.peripheralName = "Flipper Anmaa1"
        return settings
    }

    @Test func nothingIsKnownAndNothingIsWritten() throws {
        let device = try BeforeFirstUnlock(saved: saved)

        let settings = device.store.load()

        #expect(settings.protectedDataUnavailable)
        #expect(settings.apiKeyUnknown)
        #expect(settings.baseURL == "")
        // The migration did not stamp the version into the unreadable store.
        #expect(device.defaults.lockedWrites.isEmpty)
        #expect(device.secrets.writes.count == 1)
    }

    @Test func afterTheUnlockEverySettingIsBack() throws {
        let device = try BeforeFirstUnlock(saved: saved)
        _ = device.store.load()

        device.locked = false
        let settings = device.store.load()

        #expect(settings == saved)
        #expect(!settings.protectedDataUnavailable)
    }

    @Test func savingSettingsThatWereNotReadIsRefused() throws {
        let device = try BeforeFirstUnlock(saved: saved)
        var settings = device.store.load()
        settings.coreWeight = 310

        #expect(throws: SettingsError.protectedDataUnavailable) { try device.store.save(settings) }
        #expect(device.defaults.lockedWrites.isEmpty)
        #expect(device.secrets.writes.count == 1)
    }

    @Test func typingAKeyDoesNotMakeTheOtherSettingsKnown() throws {
        let device = try BeforeFirstUnlock(saved: saved)
        var settings = device.store.load()

        settings.apiKey = "bb_new"

        #expect(!settings.apiKeyUnknown)
        #expect(settings.protectedDataUnavailable)
    }

    @Test func theMigrationRunsOnlyOnceTheStoreIsReadable() throws {
        // A Phase 0 install: the old default core weight, no version yet.
        let defaults = LockableKeyValueStore()
        defaults.set(325, forKey: "bambuddy.coreWeight")
        let secrets = LockableSecretStore(key: "bb_test")
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        defaults.locked = true
        secrets.locked = true

        _ = store.load()
        #expect(defaults.lockedWrites.isEmpty)

        defaults.locked = false
        secrets.locked = false
        let settings = store.load()
        #expect(settings.coreWeight == Settings.defaultCoreWeight)
        #expect(defaults.object(forKey: "settings.version") as? Int == SettingsStore.currentVersion)
    }

    @Test func aLockedKeyBesideReadableSettingsIsOnlyAnUnknownKey() throws {
        // An item still WhenUnlocked from before 1.0, read while locked after
        // the first unlock: the stored settings are readable.
        let defaults = LockableKeyValueStore()
        let secrets = LockableSecretStore()
        try SettingsStore(defaults: defaults, secrets: secrets).save(saved)
        secrets.locked = true

        let settings = SettingsStore(defaults: defaults, secrets: secrets).load()

        #expect(settings.apiKeyUnknown)
        #expect(!settings.protectedDataUnavailable)
        #expect(settings.baseURL == saved.baseURL)
        #expect(settings.peripheralId == saved.peripheralId)
    }

    @Test func theLogSaysTheSettingsAreUnavailable() async throws {
        let device = try BeforeFirstUnlock(saved: saved)

        let sink = await capturingLog { _ = device.store.load() }

        #expect(sink.lines.contains { $0.message.contains("protected data unavailable") })
        #expect(!sink.lines.contains { $0.message.contains("bb_test") })
    }
}

@MainActor
@Suite("HostModel launched before the first unlock")
struct BeforeFirstUnlockHostModelTests {
    private static let flipperA = UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")!

    private var saved: Settings {
        var settings = testSettings
        settings.baseURL = "https://bambuddy.example.com"
        settings.coreWeight = 300
        settings.transport = .bluetooth
        settings.peripheralId = Self.flipperA
        settings.peripheralName = "Flipper Anmaa1"
        return settings
    }

    private func makeModel(
        _ device: BeforeFirstUnlock, opened: LockedBox<[TransportChoice]> = LockedBox([]),
        linkWaitsForChosenFlipper: Bool = true
    ) -> HostModel {
        HostModel(
            store: device.store, makeInventory: { _ in FakeInventory() },
            makeTransport: { choice in
                opened.mutate { $0.append(choice) }
                return FakeTransport()
            },
            discoverPorts: { [] }, linkWaitsForChosenFlipper: linkWaitsForChosenFlipper, requiresHTTPS: true
        )
    }

    /// A sender wired to `host` as `WatchSettingsSender.start(for:)` wires it.
    private func makeSender(for host: HostModel, session: FakeSessionMessaging) -> WatchSettingsSender {
        let sender = WatchSettingsSender(session: session, requireHTTPS: true)
        host.onSettingsSaved = { [weak sender] in sender?.settingsSaved($0) }
        sender.settingsProvider = { [weak host] in host?.settings }
        sender.seed(host.settings)
        if host.settings.isConfigured { sender.settingsSaved(host.settings) }
        return sender
    }

    @Test func everySettingIsBackAfterTheUnlockAndNothingWasWritten() async throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let model = makeModel(device)
        #expect(model.settings.protectedDataUnavailable)

        device.locked = false
        await model.reloadSettings()

        #expect(model.settings == saved)
        #expect(model.feed.settings == saved)
        #expect(model.spools.settings == saved)
        #expect(await model.session.settings == saved)
        #expect(device.defaults.lockedWrites.isEmpty)
        #expect(device.secrets.writes.count == 1)
    }

    @Test func theWatchNeverGetsAnEmptyURL() async throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let model = makeModel(device)
        let session = FakeSessionMessaging()
        let sender = makeSender(for: model, session: session)
        #expect(session.sent.isEmpty)

        device.locked = false
        await model.reloadSettings()

        #expect(session.sentPayloads == [SettingsSyncPayload(saved)])
        #expect(!session.sentPayloads.contains { $0.baseURL.isEmpty })
        _ = sender
    }

    @Test func aChangeBeforeTheUnlockIsRefusedAndNotSent() async throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let model = makeModel(device)
        let sent = LockedBox<[Settings]>([])
        model.onSettingsSaved = { settings in sent.mutate { $0.append(settings) } }

        var change = model.settings
        change.baseURL = "https://other.example.com"
        change.apiKey = "bb_other"
        await #expect(throws: SettingsError.protectedDataUnavailable) { try await model.apply(change) }

        #expect(sent.value.isEmpty)
        #expect(device.defaults.lockedWrites.isEmpty)
        #expect(device.secrets.writes.count == 1)
        device.locked = false
        await model.reloadSettings()
        #expect(model.settings == saved)
    }

    @Test func theLinkThatWaitedStartsWithTheRememberedFlipper() async throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let opened = LockedBox<[TransportChoice]>([])
        let model = makeModel(device, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened.value.isEmpty)

        device.locked = false
        await model.reloadSettings()

        #expect(await eventually { opened.value == [.bluetooth(peripheral: Self.flipperA)] })
    }

    @Test func theWatchLinkMovesToTheRememberedFlipper() async throws {
        // The watch connects to the first Flipper found meanwhile.
        let device = try BeforeFirstUnlock(saved: saved)
        let opened = LockedBox<[TransportChoice]>([])
        let model = makeModel(device, opened: opened, linkWaitsForChosenFlipper: false)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.link.isActive)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!opened.value.contains(.bluetooth(peripheral: Self.flipperA)))

        device.locked = false
        await model.reloadSettings()

        #expect(await eventually { opened.value.last == .bluetooth(peripheral: Self.flipperA) })
    }

    @Test func stillLockedChangesNothing() async throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let model = makeModel(device)
        let before = model.settings

        await model.reloadSettings()

        #expect(model.settings == before)
        #expect(model.settings.protectedDataUnavailable)
    }

    @Test func aBluetoothRelaunchStartsTheLinkSoTheRestoredFlipperIsKept() throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let settings = device.store.load()

        // The central must exist when launching returns, or iOS's restored
        // peripherals are lost; the link waits for the settings.
        #expect(HostModel.startsAtLaunch(relaunchedForBluetooth: true, settings: settings))
        #expect(!HostModel.startsAtLaunch(relaunchedForBluetooth: false, settings: settings))
    }

    @Test func aSettingsScreenFromBeforeTheUnlockShowsTheSettings() throws {
        let device = try BeforeFirstUnlock(saved: saved)
        let applied = LockedBox<[Settings]>([])
        let model = SettingsViewModel(
            settings: device.store.load(), makeInventory: { _ in FakeInventory() }, discoverPorts: { [] },
            appliesOnChange: true, apply: { new in applied.mutate { $0.append(new) } }
        )

        model.adoptRestoredSettings(saved)

        #expect(model.draft == saved)
        #expect(model.baseURL == saved.baseURL)
        #expect(model.apiKey == saved.apiKey)
        #expect(!model.hasChanges)
        #expect(applied.value.isEmpty)
    }
}
