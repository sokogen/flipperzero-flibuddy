import Foundation
import Testing
@testable import SpoolBuddyCore

@MainActor
@Suite("HostModel")
struct HostModelTests {
    private func makeModel(_ scratch: ScratchDefaults, inventory: FakeInventory = FakeInventory()) throws -> HostModel {
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        try store.save(testSettings)
        return HostModel(
            store: store,
            makeInventory: { _ in inventory },
            makeTransport: { _ in FakeTransport() },
            discoverPorts: { [] }
        )
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
        let model = try makeModel(scratch)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.link.choice == .usb(port: nil))

        var changed = testSettings
        changed.port = "/dev/cu.usbmodemflip_B"
        try await model.apply(changed)

        #expect(model.link.choice == .usb(port: "/dev/cu.usbmodemflip_B"))
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
