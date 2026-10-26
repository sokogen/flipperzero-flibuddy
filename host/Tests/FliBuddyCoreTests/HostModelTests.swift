import Foundation
import Testing
@testable import FliBuddyCore

@MainActor
@Suite("HostModel")
struct HostModelTests {
    private func makeModel(
        _ defaults: InMemoryKeyValueStore, settings: Settings = testSettings, inventory: FakeInventory = FakeInventory(),
        opened: LockedBox<[TransportChoice]> = LockedBox([])
    ) throws -> HostModel {
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        try store.save(settings)
        return HostModel(
            store: store,
            makeInventory: { _ in inventory },
            makeTransport: { choice in
                opened.mutate { $0.append(choice) }
                return FakeTransport()
            },
            discoverPorts: { ["/dev/cu.usbmodemflip_A"] }
        )
    }

    private static let flipperA = UUID(uuidString: "6B1E6B52-7D2C-4C8B-9E55-3A1F0F3C2D10")!
    private static let flipperB = UUID(uuidString: "0F1C2E3D-4B5A-4978-8695-A4B3C2D1E0F9")!

    private var usbSettings: Settings {
        var settings = testSettings
        settings.transport = .usb
        return settings
    }

    private var bluetoothSettings: Settings {
        var settings = testSettings
        settings.transport = .bluetooth
        settings.peripheralId = Self.flipperA
        settings.peripheralName = "Flipper Anmaa1"
        return settings
    }

    @Test func startsWithTheSavedSettings() async throws {
        let defaults = InMemoryKeyValueStore()
        let model = try makeModel(defaults)
        #expect(model.settings == testSettings)
        #expect(model.feed.settings == testSettings)
        #expect(await model.session.settings == testSettings)
        #expect(model.makeSettingsViewModel().draft == testSettings)
    }

    @Test func applyingSettingsSavesAndReconfigures() async throws {
        let defaults = InMemoryKeyValueStore()
        let inventory = FakeInventory()
        let model = try makeModel(defaults, inventory: inventory)
        var changed = testSettings
        changed.defaultMode = .net
        changed.baseURL = "http://10.0.0.5:8000"

        try await model.apply(changed)

        #expect(model.settings == changed)
        #expect(model.feed.settings == changed)
        #expect(await model.session.settings == changed)
        #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).load().baseURL == changed.baseURL)
        // The new settings are checked right away.
        #expect(await model.session.bambuddy == .ready)
        #expect(inventory.calls.contains(.spoolman))
    }

    @Test func settingsWithoutAClientLeaveBambuddyNotConfigured() async throws {
        let defaults = InMemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        let model = HostModel(
            store: store, makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }
        )

        try await model.apply(Settings())

        #expect(await model.session.bambuddy == .notConfigured)
    }

    @Test func choosingAPortReconnects() async throws {
        let defaults = InMemoryKeyValueStore()
        let model = try makeModel(defaults, settings: usbSettings)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.link.choice == .usb(port: nil))

        var changed = usbSettings
        changed.port = "/dev/cu.usbmodemflip_B"
        try await model.apply(changed)

        #expect(model.link.choice == .usb(port: "/dev/cu.usbmodemflip_B"))
    }

    @Test func startUsesTheSavedTransport() throws {
        let defaults = InMemoryKeyValueStore()
        let model = try makeModel(defaults, settings: bluetoothSettings)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.link.choice == .bluetooth(peripheral: Self.flipperA))
    }

    @Test func changingTheTransportKindReconnects() async throws {
        let defaults = InMemoryKeyValueStore()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(defaults, settings: usbSettings, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value == [.usb(port: "/dev/cu.usbmodemflip_A")] })

        var changed = usbSettings
        changed.transport = .bluetooth
        try await model.apply(changed)

        #expect(model.link.choice == .bluetooth(peripheral: nil))
        #expect(await eventually { opened.value.last == .bluetooth(peripheral: nil) })
    }

    @Test func choosingAnotherPeripheralReconnects() async throws {
        let defaults = InMemoryKeyValueStore()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(defaults, settings: bluetoothSettings, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value == [.bluetooth(peripheral: Self.flipperA)] })

        var changed = bluetoothSettings
        changed.peripheralId = Self.flipperB
        changed.peripheralName = "Flipper Brrr2"
        try await model.apply(changed)

        #expect(await eventually { opened.value.last == .bluetooth(peripheral: Self.flipperB) })
        #expect(opened.value.count == 2)
    }

    @Test func otherChangesKeepTheLink() async throws {
        let defaults = InMemoryKeyValueStore()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(defaults, settings: bluetoothSettings, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value.count == 1 })

        var changed = bluetoothSettings
        changed.baseURL = "http://10.0.0.5:8000"
        changed.peripheralName = "Flipper renamed"
        // The port only matters for USB.
        changed.port = "/dev/cu.usbmodemflip_B"
        try await model.apply(changed)

        try await Task.sleep(for: .milliseconds(100))
        #expect(opened.value.count == 1)
        #expect(model.link.choice == .bluetooth(peripheral: Self.flipperA))
    }

    @Test func aChangeBeforeStartDoesNotConnect() async throws {
        let defaults = InMemoryKeyValueStore()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(defaults, settings: usbSettings, opened: opened)

        try await model.apply(bluetoothSettings)

        #expect(!model.link.isActive)
        #expect(opened.value.isEmpty)
    }

    @Test func startingAgainKeepsTheRunningLink() async throws {
        // Every window's `.task` calls `start()`; a second window must not
        // reopen the port under a running scan or intent.
        let defaults = InMemoryKeyValueStore()
        let transport = FakeTransport()
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        try store.save(testSettings)
        let model = HostModel(
            store: store, makeInventory: { _ in FakeInventory() },
            makeTransport: { _ in transport }, discoverPorts: { ["/dev/cu.usbmodemflip_A"] }
        )
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { transport.state == .open })

        model.start()

        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.connectCount == 1)
        #expect(transport.state == .open)
    }

    @Test func theSaveHookRunsAfterEverySaveOnly() async throws {
        let defaults = InMemoryKeyValueStore()
        let model = try makeModel(defaults)
        var saved: [Settings] = []
        model.onSettingsSaved = { saved.append($0) }
        model.start()
        defer { model.link.disconnect() }
        #expect(saved.isEmpty)

        var changed = testSettings
        changed.coreWeight = 300
        try await model.apply(changed)
        try await model.apply(changed)

        #expect(saved == [changed, changed])
    }

    @Test func aFailedSaveSkipsTheHook() async throws {
        let defaults = InMemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: FailingSecretStore())
        let model = HostModel(store: store, makeTransport: { _ in FakeTransport() }, discoverPorts: { [] })
        var saved: [Settings] = []
        model.onSettingsSaved = { saved.append($0) }

        await #expect(throws: SecretStoreError.status(-25300)) { try await model.apply(testSettings) }

        #expect(saved.isEmpty)
    }

    @Test func usingAFlipperRemembersItAndReconnects() async throws {
        let defaults = InMemoryKeyValueStore()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(defaults, settings: bluetoothSettings, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value.count == 1 })

        try await model.useFlipper(DiscoveredPeripheral(id: Self.flipperB, name: "Flipper Brrr2", rssi: -60))

        var expected = bluetoothSettings
        expected.peripheralId = Self.flipperB
        expected.peripheralName = "Flipper Brrr2"
        #expect(model.settings == expected)
        #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).load().peripheralId == Self.flipperB)
        #expect(await eventually { opened.value.last == .bluetooth(peripheral: Self.flipperB) })
    }

    @Test func usingAFlipperSwitchesToBluetooth() async throws {
        let defaults = InMemoryKeyValueStore()
        let model = try makeModel(defaults, settings: usbSettings)

        try await model.useFlipper(DiscoveredPeripheral(id: Self.flipperA, name: "Flipper Anmaa1", rssi: -50))

        #expect(model.settings.transport == .bluetooth)
        #expect(model.settings.peripheralId == Self.flipperA)
        #expect(model.settings.baseURL == usbSettings.baseURL)
    }

    @Test func theHostHelloNamesTheApp() {
        let hello = HostModel.hostHello
        #expect(hello.app == "flibuddy-mac/0.1.0")
        #expect(hello.os == PlatformInfo.current)
        #if os(macOS)
        #expect(hello.os?.hasPrefix("macOS ") == true)
        #endif
        #expect(throws: Never.self) { try hello.validate() }
    }
}
