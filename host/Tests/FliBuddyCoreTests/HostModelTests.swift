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
        #expect(model.makeSettingsViewModel().connectionLine == "No Flipper paired")
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

    @Test func aChangeThatKeepsTheServerAndKeyKeepsTheFeedAsItIs() async throws {
        let defaults = InMemoryKeyValueStore()
        let picked = Spool(id: 7, material: "PLA", labelWeight: 1000, coreWeight: 250, weightUsed: 400)
        let inventory = FakeInventory(spools: [picked])
        let model = try makeModel(defaults, inventory: inventory)
        _ = await model.session.handleScan(try autosaveScan())
        let row = try #require(await model.session.rows.first)
        #expect(row.createdSpoolId == 100)
        #expect(inventory.colorMapLoads == 1)
        var changed = testSettings
        changed.defaultMode = .net
        changed.coreWeight = 200
        changed.catalogEntryId = nil

        try await model.apply(changed)

        #expect(await model.session.settings == changed)
        #expect(await model.session.rows.first?.createdSpoolId == 100)
        #expect(await model.session.bambuddy == .ready)
        #expect(inventory.colorMapLoads == 1)
        // Link still deletes the spool created on scan, so Bambuddy takes the tag.
        try await model.session.link(row: row.id, toSpool: 7, from: try await model.session.listSpools())
        #expect(inventory.calls.contains(.delete(spoolId: 100)))
        #expect(inventory.calls.last == .link(spoolId: 7, TagLink(tag: row.tag)))
    }

    @Test func anotherServerOrKeyReconfiguresTheSession() async throws {
        for change in [\Settings.baseURL, \Settings.apiKey] {
            let defaults = InMemoryKeyValueStore()
            let inventory = FakeInventory()
            let model = try makeModel(defaults, inventory: inventory)
            _ = await model.session.handleScan(try autosaveScan())
            #expect(await model.session.rows.first?.createdSpoolId == 100)
            var changed = testSettings
            changed[keyPath: change] += "x"

            try await model.apply(changed)

            #expect(await model.session.settings == changed)
            #expect(await model.session.rows.first?.createdSpoolId == nil)
            #expect(inventory.colorMapLoads == 2)
        }
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

    @Test func theLinkStartsAtLaunchOnlyForARememberedFlipper() {
        var fresh = testSettings
        fresh.transport = .bluetooth
        #expect(!HostModel.startsAtLaunch(relaunchedForBluetooth: false, settings: fresh))
        // A relaunch for Bluetooth without a remembered Flipper has nothing
        // to restore: the link would only wait, so no central for nothing.
        #expect(!HostModel.startsAtLaunch(relaunchedForBluetooth: true, settings: fresh))
        #expect(HostModel.startsAtLaunch(relaunchedForBluetooth: false, settings: bluetoothSettings))
        #expect(HostModel.startsAtLaunch(relaunchedForBluetooth: true, settings: bluetoothSettings))
        var usb = bluetoothSettings
        usb.transport = .usb
        #expect(!HostModel.startsAtLaunch(relaunchedForBluetooth: false, settings: usb))
    }

    @Test func forgettingTheFlipperStopsAWaitingPlatformsLink() async throws {
        // It would otherwise reconnect to the first Flipper found.
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeBluetoothOnlyModel(settings: bluetoothSettings, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value.count == 1 })

        var forgotten = bluetoothSettings
        forgotten.peripheralId = nil
        forgotten.peripheralName = nil
        try await model.apply(forgotten)

        #expect(!model.link.isActive)
        try await Task.sleep(for: .milliseconds(100))
        #expect(opened.value == [.bluetooth(peripheral: Self.flipperA)])
        // Choosing one again starts it.
        try await model.useFlipper(DiscoveredPeripheral(id: Self.flipperB, name: "Flipper Brrr2", rssi: -60))
        #expect(await eventually { opened.value.last == .bluetooth(peripheral: Self.flipperB) })
    }

    @Test func theMacKeepsTheFirstFoundFlipperAfterForget() async throws {
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(InMemoryKeyValueStore(), settings: bluetoothSettings, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { opened.value.count == 1 })

        var forgotten = bluetoothSettings
        forgotten.peripheralId = nil
        try await model.apply(forgotten)

        #expect(model.link.isActive)
        #expect(await eventually { opened.value.last == .bluetooth(peripheral: nil) })
    }

    // MARK: First run

    /// A host on a Bluetooth-only platform (iPhone, iPad, Watch).
    private func makeBluetoothOnlyModel(
        settings: Settings, opened: LockedBox<[TransportChoice]>, defaults: InMemoryKeyValueStore = InMemoryKeyValueStore()
    ) throws -> HostModel {
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        try store.save(settings)
        return HostModel(
            store: store, makeInventory: { _ in FakeInventory() },
            makeTransport: { choice in
                opened.mutate { $0.append(choice) }
                return FakeTransport()
            },
            discoverPorts: { [] }, linkWaitsForChosenFlipper: true
        )
    }

    @Test func withoutARememberedFlipperTheLinkWaitsForOneToBeChosen() async throws {
        // Creating the Bluetooth central asks for permission: a fresh
        // install asks only when the user scans for a Flipper.
        var fresh = testSettings
        fresh.transport = .bluetooth
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeBluetoothOnlyModel(settings: fresh, opened: opened)

        model.start()
        defer { model.link.disconnect() }

        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.link.isActive)
        #expect(opened.value.isEmpty)
        // Bambuddy is still checked.
        #expect(await eventually { await model.session.bambuddy == .ready })
    }

    @Test func choosingTheFirstFlipperStartsTheWaitingLink() async throws {
        var fresh = testSettings
        fresh.transport = .bluetooth
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeBluetoothOnlyModel(settings: fresh, opened: opened)
        model.start()
        defer { model.link.disconnect() }

        try await model.useFlipper(DiscoveredPeripheral(id: Self.flipperA, name: "Flipper Anmaa1", rssi: -50))

        #expect(model.link.isActive)
        #expect(await eventually { opened.value == [.bluetooth(peripheral: Self.flipperA)] })
    }

    @Test func aChosenFlipperBeforeStartStillWaitsForStart() async throws {
        var fresh = testSettings
        fresh.transport = .bluetooth
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeBluetoothOnlyModel(settings: fresh, opened: opened)

        try await model.useFlipper(DiscoveredPeripheral(id: Self.flipperA, name: "Flipper Anmaa1", rssi: -50))

        #expect(!model.link.isActive)
        #expect(opened.value.isEmpty)
    }

    @Test func aRememberedFlipperStartsTheLinkOnABluetoothOnlyPlatform() async throws {
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeBluetoothOnlyModel(settings: bluetoothSettings, opened: opened)

        model.start()
        defer { model.link.disconnect() }

        #expect(await eventually { opened.value == [.bluetooth(peripheral: Self.flipperA)] })
    }

    @Test func theMacStartsTheLinkWithoutARememberedFlipper() async throws {
        var any = testSettings
        any.transport = .bluetooth
        let opened = LockedBox<[TransportChoice]>([])
        let model = try makeModel(InMemoryKeyValueStore(), settings: any, opened: opened)

        model.start()
        defer { model.link.disconnect() }

        #expect(await eventually { opened.value == [.bluetooth(peripheral: nil)] })
    }

    @Test func theFeedSaysWhatIsMissingFirst() async throws {
        let opened = LockedBox<[TransportChoice]>([])
        var fresh = Settings()
        fresh.transport = .bluetooth
        let model = try makeBluetoothOnlyModel(settings: fresh, opened: opened)
        model.start()
        defer { model.link.disconnect() }
        #expect(model.feedEmptyState == .noServer)

        var configured = testSettings
        configured.transport = .bluetooth
        try await model.apply(configured)
        #expect(model.feedEmptyState == .noFlipper)

        try await model.useFlipper(DiscoveredPeripheral(id: Self.flipperA, name: "Flipper Anmaa1", rssi: -50))
        // Searching for the Flipper is not a Flipper yet.
        #expect(model.feedEmptyState == .noFlipper)
    }

    @Test func aConnectedFlipperLeavesTheScanHint() async throws {
        let transport = FakeTransport()
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        try store.save(bluetoothSettings)
        let model = HostModel(
            store: store, makeInventory: { _ in FakeInventory() }, makeTransport: { _ in transport },
            discoverPorts: { [] }, linkWaitsForChosenFlipper: true
        )
        model.start()
        defer { model.link.disconnect() }
        #expect(await eventually { transport.state == .open })
        transport.deliver(.flipperHello)

        #expect(await eventually { model.feedEmptyState == .noScans })
    }

    @Test func anHTTPAddressAsksForHTTPSInTheFeed() throws {
        var http = testSettings
        http.transport = .bluetooth
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        try store.save(http)
        let model = HostModel(
            store: store, makeInventory: { try $0.makeClient(requireHTTPS: true) },
            makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }, requiresHTTPS: true
        )
        #expect(model.feedEmptyState == .needsHTTPS)
    }

    @Test func aStoredHTTPAddressIsCheckedAsNeedingHTTPS() async throws {
        // Settings saved before HTTPS only (Phase 0 kept http://).
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        try store.save(testSettings)
        let model = HostModel(
            store: store, makeInventory: { try $0.makeClient(requireHTTPS: true) },
            makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }, requiresHTTPS: true
        )

        await model.checkBambuddy()

        #expect(await model.session.bambuddy == .needsHTTPS)
        model.feed.apply(await model.session.snapshot)
        // The empty feed says it with its Settings button; the sidebar keeps the line.
        #expect(model.feedEmptyState == .needsHTTPS)
        #expect(!model.connectionBanner.lines.map(\.text).contains("Bambuddy needs HTTPS"))
        #expect(model.sidebar.bambuddy.subline == "Needs HTTPS")
    }

    @Test func theEmptyFeedNamesTheSameServerStateAsTheSpools() {
        let noServer = FeedEmptyState.noServer.content
        let spools = SpoolsViewModel.Unavailable.connectBambuddy
        #expect(noServer.title == spools.title)
        #expect(noServer.message == spools.message)
        #expect(noServer.systemImage == spools.systemImage)
        #expect(noServer.actionTitle == "Open Settings")
        let https = FeedEmptyState.needsHTTPS.content
        #expect(https.title == SpoolsViewModel.Unavailable.needsHTTPS.title)
        #expect(https.message == SpoolsViewModel.Unavailable.needsHTTPS.message)
        #expect(https.actionTitle == "Open Settings")
        let noFlipper = FeedEmptyState.noFlipper.content
        #expect(noFlipper.title == "Find your Flipper")
        #expect(noFlipper.message == "Open FliBuddy on the Flipper (Apps\u{00A0}\u{2192}\u{00A0}NFC).")
        #expect(noFlipper.actionTitle == "Scan for Flipper")
        let noScans = FeedEmptyState.noScans.content
        #expect(noScans.title == "No scans yet")
        #expect(noScans.message == "Hold a spool's tag to the Flipper running FliBuddy.")
        #expect(noScans.actionTitle == nil)
    }

    @Test func theHostHelloNamesTheApp() {
        let hello = HostModel.hostHello
        #expect(hello.app.hasPrefix("flibuddy-mac/"))
        #expect(hello.app.split(separator: "/").count == 2)
        #expect(hello.os == PlatformInfo.current)
        #if os(macOS)
        #expect(hello.os?.hasPrefix("macOS ") == true)
        #endif
        #expect(throws: Never.self) { try hello.validate() }
    }

    @Test func theHelloNamesThePlatformsAppAndTheBundleVersion() throws {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "214"]
        #expect(FliBuddyCore.app(.iOS, info: info) == "flibuddy-ios/1.0.0")
        #expect(FliBuddyCore.app(.iPadOS, info: info) == "flibuddy-ios/1.0.0")
        #expect(FliBuddyCore.app(.watchOS, info: info) == "flibuddy-watch/1.0.0")
        #expect(FliBuddyCore.app(.macOS, info: info) == "flibuddy-mac/1.0.0")
        // Without a bundle version (swift test, a bare binary).
        #expect(FliBuddyCore.app(.iOS, info: nil) == "flibuddy-ios/dev")
        #expect(FliBuddyCore.app(.iOS, info: ["CFBundleShortVersionString": "  "]) == "flibuddy-ios/dev")
        // The protocol caps `app` at 40 characters.
        let long = FliBuddyCore.app(.watchOS, info: ["CFBundleShortVersionString": String(repeating: "9", count: 60)])
        #expect(long.count == 40)
        #expect(throws: Never.self) { try Hello(app: long, os: "watchOS 26.0").validate() }
    }

    // MARK: Spools

    @Test func anotherBambuddyReloadsTheSpoolsAndTheSidebarCountsThem() async throws {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        try store.save(testSettings)
        let first = FakeInventory(spools: [knownSpool()])
        let second = FakeInventory(spools: [])
        let model = HostModel(
            store: store,
            makeInventory: { $0.baseURL == testSettings.baseURL ? first : second },
            makeTransport: { _ in FakeTransport() }, discoverPorts: { [] }
        )
        #expect(model.sidebar.spoolCount == nil)
        await model.spools.refresh()
        #expect(model.sidebar.spoolCount == 1)
        var other = testSettings
        other.baseURL = "http://other.test:8000"
        try await model.apply(other)
        #expect(second.calls.contains(.listAll))
        #expect(model.sidebar.spoolCount == 0)
        #expect(model.spools.detail(for: 42) == nil)
    }

    @Test func otherSettingsKeepTheSpools() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let model = try makeModel(InMemoryKeyValueStore(), inventory: inventory)
        await model.spools.refresh()
        var settings = testSettings
        settings.coreWeight = 200
        try await model.apply(settings)
        #expect(inventory.calls.filter { $0 == .listAll }.count == 1)
        #expect(model.sidebar.spoolCount == 1)
    }
}
