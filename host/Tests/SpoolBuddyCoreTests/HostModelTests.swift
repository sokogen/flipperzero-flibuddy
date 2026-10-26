import Foundation
import Testing
@testable import SpoolBuddyCore

@MainActor
@Suite("HostModel")
struct HostModelTests {
    private func makeModel(
        _ scratch: ScratchDefaults, settings: Settings = testSettings, inventory: FakeInventory = FakeInventory(),
        opened: LockedBox<[TransportChoice]> = LockedBox([])
    ) throws -> HostModel {
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
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
        let scratch = ScratchDefaults()
        let model = try makeModel(scratch)
        #expect(model.settings == testSettings)
        #expect(model.feed.settings == testSettings)
        #expect(await model.session.settings == testSettings)
        #expect(model.makeSettingsViewModel().draft == testSettings)
    }

    @Test func applyingSettingsSavesAndReconfigures() async throws {
        let scratch = ScratchDefaults()
        let inventory = FakeInventory()
        let model = try makeModel(scratch, inventory: inventory)
        var changed = testSettings
        changed.defaultMode = .net
        changed.baseURL = "http://10.0.0.5:8000"

        try await model.apply(changed)

        #expect(model.settings == changed)
        #expect(model.feed.settings == changed)
        #expect(await model.session.settings == changed)
        #expect(SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore()).load().baseURL == changed.baseURL)
        // The new settings are checked right away.
        #expect(await model.session.bambuddy == .ready)
        #expect(inventory.calls.contains(.spoolman))
    }

    @Test func settingsWithoutAClientLeaveBambuddyNotConfigured() async throws {
        let scratch = ScratchDefaults()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let model = HostModel(
            store: store, makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }
        )

        try await model.apply(Settings())

        #expect(await model.session.bambuddy == .notConfigured)
    }

    @Test func choosingAPortReconnects() async throws {
        let scratch = ScratchDefaults()
        let model = try makeModel(scratch, settings: usbSettings)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.link.choice == .usb(port: nil))

        var changed = usbSettings
        changed.port = "/dev/cu.usbmodemflip_B"
        try await model.apply(changed)

        #expect(model.link.choice == .usb(port: "/dev/cu.usbmodemflip_B"))
    }

    @Test func startUsesTheSavedTransport() throws {
        let scratch = ScratchDefaults()
        let model = try makeModel(scratch, settings: bluetoothSettings)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.link.choice == .bluetooth(peripheral: Self.flipperA))
    }

    @Test func changingTheTransportKindReconnects() async throws {
        let scratch = ScratchDefaults()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(scratch, settings: usbSettings, opened: opened)
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
        let scratch = ScratchDefaults()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(scratch, settings: bluetoothSettings, opened: opened)
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
        let scratch = ScratchDefaults()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(scratch, settings: bluetoothSettings, opened: opened)
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
        let scratch = ScratchDefaults()
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(scratch, settings: usbSettings, opened: opened)

        try await model.apply(bluetoothSettings)

        #expect(!model.link.isActive)
        #expect(opened.value.isEmpty)
    }

    @Test func startingAgainKeepsTheRunningLink() async throws {
        // Every window's `.task` calls `start()`; a second window must not
        // reopen the port under a running scan or intent.
        let scratch = ScratchDefaults()
        let transport = FakeTransport()
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
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

    @Test func theHostHelloNamesTheApp() {
        let hello = HostModel.hostHello
        #expect(hello.app == "spoolbuddy-mac/0.1.0")
        #expect(hello.os == PlatformInfo.current)
        #if os(macOS)
        #expect(hello.os?.hasPrefix("macOS ") == true)
        #endif
        #expect(throws: Never.self) { try hello.validate() }
    }
}
