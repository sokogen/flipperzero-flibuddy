import Foundation
import Testing
@testable import FliBuddyCore

/// A WatchConnectivity session that records what was sent.
final class FakeSessionMessaging: SessionMessaging, @unchecked Sendable {
    var isSupported = true
    var isActivated = true
    var isCounterpartInstalled = true
    var failure: (any Error)?
    private(set) var sent: [[String: Any]] = []

    func updateApplicationContext(_ context: [String: Any]) throws {
        if let failure { throw failure }
        sent.append(context)
    }

    var sentPayloads: [SettingsSyncPayload] {
        sent.compactMap { try? SettingsSyncPayload(dictionary: $0) }
    }
}

private struct SendFailed: Error, LocalizedError {
    var errorDescription: String? { "Watch not reachable" }
}

@MainActor
@Suite("WatchSettingsSender")
struct WatchSettingsSenderTests {
    @Test func sendsTheSavedSettings() {
        let session = FakeSessionMessaging()
        let sender = WatchSettingsSender(session: session)

        sender.settingsSaved(testSettings)

        #expect(session.sentPayloads == [SettingsSyncPayload(testSettings)])
        #expect(sender.lastError == nil)
    }

    @Test func sendsNothingUntilSettingsAreSaved() {
        let session = FakeSessionMessaging()
        let sender = WatchSettingsSender(session: session)

        sender.sessionStateChanged()

        #expect(session.sent.isEmpty)
    }

    @Test func sendsNothingWithoutTheWatchApp() {
        let session = FakeSessionMessaging()
        session.isCounterpartInstalled = false
        let sender = WatchSettingsSender(session: session)

        sender.settingsSaved(testSettings)
        sender.sessionStateChanged()

        #expect(session.sent.isEmpty)
    }

    @Test func sendsNothingWhereWatchConnectivityIsUnsupported() {
        // iPad: WCSession.isSupported() is false.
        let session = FakeSessionMessaging()
        session.isSupported = false
        let sender = WatchSettingsSender(session: session)

        sender.settingsSaved(testSettings)
        sender.sessionStateChanged()

        #expect(session.sent.isEmpty)
        #expect(sender.lastError == nil)
    }

    @Test func holdsTheSettingsUntilTheSessionIsActivated() {
        let session = FakeSessionMessaging()
        session.isActivated = false
        let sender = WatchSettingsSender(session: session)

        sender.settingsSaved(testSettings)
        #expect(session.sent.isEmpty)

        session.isActivated = true
        sender.sessionStateChanged()
        #expect(session.sentPayloads == [SettingsSyncPayload(testSettings)])

        // Sent once; a later state change does not repeat it.
        sender.sessionStateChanged()
        #expect(session.sent.count == 1)
    }

    @Test func sendsOnceTheWatchAppIsInstalled() {
        let session = FakeSessionMessaging()
        session.isCounterpartInstalled = false
        let sender = WatchSettingsSender(session: session)
        sender.settingsSaved(testSettings)

        session.isCounterpartInstalled = true
        sender.sessionStateChanged()

        #expect(session.sentPayloads == [SettingsSyncPayload(testSettings)])
    }

    @Test func onlyTheLatestSaveIsHeld() {
        let session = FakeSessionMessaging()
        session.isActivated = false
        let sender = WatchSettingsSender(session: session)
        var changed = testSettings
        changed.coreWeight = 300

        sender.settingsSaved(testSettings)
        sender.settingsSaved(changed)
        session.isActivated = true
        sender.sessionStateChanged()

        #expect(session.sentPayloads == [SettingsSyncPayload(changed)])
    }

    @Test func aFailedSendIsReportedAndRetried() {
        let session = FakeSessionMessaging()
        session.failure = SendFailed()
        let sender = WatchSettingsSender(session: session)

        sender.settingsSaved(testSettings)
        #expect(sender.lastError == "Watch not reachable")

        session.failure = nil
        sender.sessionStateChanged()
        #expect(session.sentPayloads == [SettingsSyncPayload(testSettings)])
        #expect(sender.lastError == nil)
    }

    @Test func theHostModelHookSendsOnSaveOnly() async throws {
        let defaults = InMemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        try store.save(testSettings)
        let session = FakeSessionMessaging()
        let sender = WatchSettingsSender(session: session)
        let model = HostModel(
            store: store, makeInventory: { _ in FakeInventory() }, makeTransport: { _ in FakeTransport() },
            discoverPorts: { [] }
        )
        model.onSettingsSaved = { sender.settingsSaved($0) }
        model.start()
        defer { model.link.disconnect() }
        #expect(session.sent.isEmpty)

        var changed = testSettings
        changed.baseURL = "http://10.0.0.5:8000"
        try await model.apply(changed)

        #expect(session.sentPayloads == [SettingsSyncPayload(changed)])
    }
}

@MainActor
@Suite("WatchSettingsReceiver")
struct WatchSettingsReceiverTests {
    private static let flipper = UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")!

    private static let phone = SettingsSyncPayload(
        baseURL: "http://192.168.1.20:8000", apiKey: "bb_phone", coreWeight: 293, catalogEntryId: 24, defaultMode: .net
    )

    /// A watch that knows its Flipper but nothing about Bambuddy yet.
    private func makeWatch(
        _ defaults: InMemoryKeyValueStore, inventory: FakeInventory = FakeInventory(),
        opened: LockedBox<[TransportChoice]> = LockedBox([])
    ) throws -> (HostModel, SettingsStore) {
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        try store.save(Settings(transport: .bluetooth, peripheralId: Self.flipper, peripheralName: "Flipper Anmaa1"))
        let model = HostModel(
            store: store, makeInventory: { _ in inventory },
            makeTransport: { choice in
                opened.mutate { $0.append(choice) }
                return FakeTransport()
            },
            discoverPorts: { [] }
        )
        return (model, store)
    }

    @Test func storesThePayloadAndReconfigures() async throws {
        let defaults = InMemoryKeyValueStore()
        let inventory = FakeInventory()
        let opened = LockedBox<[TransportChoice]>([])
        let (model, store) = try makeWatch(defaults, inventory: inventory, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value.count == 1 })
        let receiver = WatchSettingsReceiver(host: model)

        await receiver.receive(.success(Self.phone))

        let saved = store.load()
        #expect(SettingsSyncPayload(saved) == Self.phone)
        #expect(saved.apiKey == "bb_phone")
        // The watch keeps its own Flipper.
        #expect(saved.transport == .bluetooth)
        #expect(saved.peripheralId == Self.flipper)
        #expect(saved.peripheralName == "Flipper Anmaa1")
        #expect(model.settings == saved)
        #expect(model.feed.settings == saved)
        #expect(await model.session.settings == saved)
        #expect(await model.session.bambuddy == .ready)
        #expect(receiver.lastError == nil)
        #expect(receiver.lastReceived != nil)
        // No transport change, so the link stays.
        try await Task.sleep(for: .milliseconds(100))
        #expect(opened.value.count == 1)
    }

    @Test func aRejectedPayloadChangesNothing() async throws {
        let defaults = InMemoryKeyValueStore()
        let (model, store) = try makeWatch(defaults)
        let before = store.load()
        let receiver = WatchSettingsReceiver(host: model)

        await receiver.receive(.failure(.unsupportedVersion(2)))

        #expect(store.load() == before)
        #expect(model.settings == before)
        #expect(receiver.lastError == SettingsSyncError.unsupportedVersion(2).localizedDescription)
        #expect(receiver.lastReceived == nil)
    }

    @Test func theSameSettingsAreNotAppliedAgain() async throws {
        let defaults = InMemoryKeyValueStore()
        let inventory = FakeInventory()
        let (model, _) = try makeWatch(defaults, inventory: inventory)
        let receiver = WatchSettingsReceiver(host: model)
        await receiver.receive(.success(Self.phone))
        let checks = inventory.calls.filter { $0 == .spoolman }.count

        await receiver.receive(.success(Self.phone))

        #expect(inventory.calls.filter { $0 == .spoolman }.count == checks)
    }

    @Test func aFailedSaveIsReportedAndChangesNothing() async throws {
        let defaults = InMemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: FailingSecretStore())
        let model = HostModel(
            store: store, makeInventory: { _ in FakeInventory() },
            makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }
        )
        let before = model.settings
        let receiver = WatchSettingsReceiver(host: model)

        await receiver.receive(.success(Self.phone))

        #expect(model.settings == before)
        #expect(receiver.lastError == Session.describe(SecretStoreError.status(-25300)))
    }

    @Test func aGoodPayloadClearsAnEarlierError() async throws {
        let defaults = InMemoryKeyValueStore()
        let (model, _) = try makeWatch(defaults)
        let receiver = WatchSettingsReceiver(host: model)
        await receiver.receive(.failure(.missingField("apiKey")))

        await receiver.receive(.success(Self.phone))

        #expect(receiver.lastError == nil)
        #expect(model.settings.apiKey == "bb_phone")
    }
}

@MainActor
@Suite("WatchSettingsSender: log")
struct WatchSettingsSenderLogTests {
    @Test func aSentPayloadIsLoggedByVersionOnly() async {
        var settings = testSettings
        settings.apiKey = "secret-key-123"
        let sender = WatchSettingsSender(session: FakeSessionMessaging())

        let sink = await capturingLog { sender.settingsSaved(settings) }

        #expect(sink.events == ["sync sent: v=1"])
    }

    @Test func aHeldAndAFailedSendAreLogged() async {
        let session = FakeSessionMessaging()
        session.isCounterpartInstalled = false
        let sender = WatchSettingsSender(session: session)

        let sink = await capturingLog(level: .debug) {
            sender.settingsSaved(testSettings)
            session.isCounterpartInstalled = true
            session.failure = SendFailed()
            sender.sessionStateChanged()
        }

        #expect(sink.events == ["sync held: reason=no watch app", "sync send failed: error=Watch not reachable"])
        #expect(sink.lines.map(\.level) == [.debug, .error])
    }

    @Test func aSendHeldOnAnUnsupportedOrInactiveSessionIsLoggedWithTheReason() async {
        let session = FakeSessionMessaging()
        session.isSupported = false
        let sender = WatchSettingsSender(session: session)

        let sink = await capturingLog(level: .debug) {
            sender.settingsSaved(testSettings)
            session.isSupported = true
            session.isActivated = false
            sender.sessionStateChanged()
        }

        #expect(sink.events == ["sync held: reason=unsupported", "sync held: reason=not activated"])
    }
}

extension WatchSettingsReceiverTests {
    @Test func aReceivedPayloadIsLoggedByVersionOnly() async throws {
        let (model, _) = try makeWatch(InMemoryKeyValueStore())
        let receiver = WatchSettingsReceiver(host: model)
        var payload = Self.phone
        payload.apiKey = "secret-key-123"

        let sink = await capturingLog {
            await receiver.receive(.success(payload))
            await receiver.receive(.success(payload))
        }

        #expect(sink.events("sync") == [
            "sync received: v=1", "sync applied", "sync received: v=1", "sync unchanged",
        ])
        #expect(!sink.lines.contains { $0.message.contains("secret-key-123") })
    }

    @Test func aRejectedPayloadAndAFailedSaveAreErrors() async throws {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: FailingSecretStore())
        let model = HostModel(
            store: store, makeInventory: { _ in FakeInventory() },
            makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }
        )
        let receiver = WatchSettingsReceiver(host: model)

        let sink = await capturingLog {
            await receiver.receive(.failure(.unsupportedVersion(2)))
            await receiver.receive(.success(Self.phone))
        }

        let lines = sink.lines.filter { $0.category == .sync }
        #expect(lines.map(\.message) == [
            "rejected: error=Settings from the iPhone have version 2; update FliBuddy",
            "received: v=1",
            "apply failed: error=\(Session.describe(SecretStoreError.status(-25300)))",
        ])
        #expect(lines.map(\.level) == [.error, .info, .error])
    }
}
