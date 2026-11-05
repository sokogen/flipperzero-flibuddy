import Foundation
import Testing
@testable import FliBuddyCore

@MainActor
@Suite("Status bar items")
struct StatusItemTests {
    private static let fap = Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1")
    private static let usb = TransportChoice.usb(port: nil)
    private static let bluetooth = TransportChoice.bluetooth(peripheral: nil)

    private func flipper(
        _ state: LinkState, choice: TransportChoice? = usb, problem: String? = nil,
        port: String? = nil, isActive: Bool = true
    ) -> StatusItem {
        FlipperLink.statusItem(state, choice: choice, port: port, problem: problem, isActive: isActive)
    }

    // MARK: Flipper

    @Test func searchingWhileNoFlipperAnswers() {
        let searching = StatusItem(
            text: "No Flipper \u{00B7} searching", symbol: .progress, tint: .gray
        )
        #expect(flipper(.disconnected) == searching)
        #expect(flipper(.disconnected, choice: Self.bluetooth) == searching)
        #expect(flipper(.waitingForHello) == searching)
        var notFound = searching
        notFound.detail = FlipperLink.noFlipperFound
        #expect(flipper(.disconnected, problem: FlipperLink.noFlipperFound) == notFound)
        notFound.detail = "No Flipper found over Bluetooth"
        #expect(flipper(.disconnected, choice: Self.bluetooth, problem: "No Flipper found over Bluetooth") == notFound)
    }

    @Test func aProblemThatIsNotJustAMissingFlipperIsShown() {
        #expect(
            flipper(.disconnected, choice: Self.bluetooth, problem: "Bluetooth is off")
                == StatusItem(
                    text: "Bluetooth is off", symbol: .symbol("antenna.radiowaves.left.and.right.slash"),
                    tint: .orange, detail: "Bluetooth is off"
                )
        )
    }

    @Test func connectedNamesTheTransport() {
        #expect(
            flipper(.connected(Self.fap), port: "/dev/cu.usbmodemflip_A")
                == StatusItem(
                    text: "Flipper \u{00B7} USB", symbol: .symbol("cable.connector"), tint: .green,
                    detail: "/dev/cu.usbmodemflip_A \u{00B7} firmware 1.5.1"
                )
        )
        #expect(
            flipper(.connected(Self.fap), choice: Self.bluetooth)
                == StatusItem(
                    text: "Flipper \u{00B7} Bluetooth", symbol: .symbol("antenna.radiowaves.left.and.right"),
                    tint: .green, detail: "firmware 1.5.1", short: "Flipper connected"
                )
        )
        #expect(flipper(.connected(Hello(app: "flibuddy-fap/0.1.0")), port: nil).detail == nil)
    }

    @Test func noHelloAsksToOpenTheApp() {
        #expect(
            flipper(.noAnswer)
                == StatusItem(text: "Open FliBuddy on the Flipper", symbol: .symbol("app.dashed"), tint: .orange)
        )
    }

    @Test func aFlipperOfAnotherVersionSaysWhatToUpdate() {
        #expect(
            flipper(.otherVersion(1))
                == StatusItem(
                    text: "Flipper speaks protocol 1, host speaks 2", symbol: .symbol("exclamationmark.triangle"),
                    tint: .orange, detail: "Install the matching FliBuddy app on the Flipper"
                )
        )
        #expect(flipper(.otherVersion(3)).detail == "Update FliBuddy on this device")
    }

    @Test func aStoppedLinkSendsToSettings() {
        // A link not started (no Flipper chosen yet on the iPhone): Connect
        // would ask for Bluetooth outside Scan for Flipper.
        #expect(
            flipper(.disconnected, choice: nil, isActive: false)
                == StatusItem(
                    text: "Flipper not connected", symbol: .symbol("antenna.radiowaves.left.and.right"),
                    tint: .orange, action: .settings
                )
        )
    }

    @Test func theLinkReportsItsOwnItem() {
        let link = FlipperLink(session: Session(settings: testSettings, inventory: nil), hello: Hello(app: "x"))
        #expect(link.statusItem.action == .settings)
    }

    // MARK: Bambuddy

    @Test func bambuddyItems() {
        #expect(
            BambuddyState.unchecked.statusItem()
                == StatusItem(
                    text: "Bambuddy \u{00B7} not checked", symbol: .symbol("server.rack"), tint: .gray, action: .check,
                    short: "Bambuddy not checked"
                )
        )
        #expect(
            BambuddyState.ready.statusItem()
                == StatusItem(text: "Bambuddy ready", symbol: .symbol("server.rack"), tint: .green)
        )
        #expect(
            BambuddyState.unreachable("Bambuddy unreachable: timed out").statusItem()
                == StatusItem(
                    text: "Bambuddy unreachable", symbol: .symbol("wifi.exclamationmark"), tint: .red,
                    action: .retry, detail: "Bambuddy unreachable: timed out"
                )
        )
        let noPermission = BambuddyState.refused(.permissionMissing("inventory:read"))
        #expect(
            noPermission.statusItem()
                == StatusItem(
                    text: "API key lacks inventory permission",
                    symbol: .symbol("lock.trianglebadge.exclamationmark"), tint: .red, action: .settings,
                    detail: noPermission.message, short: "Key lacks inventory permission"
                )
        )
        let spoolman = BambuddyState.refused(.spoolmanMode)
        #expect(
            spoolman.statusItem()
                == StatusItem(
                    text: "Bambuddy is in Spoolman mode", symbol: .symbol("nosign"), tint: .red, action: .retry,
                    detail: spoolman.message
                )
        )
    }

    @Test func statesTheSpecLeavesOutPointToSettings() {
        let notConfigured = BambuddyState.notConfigured
        #expect(
            notConfigured.statusItem()
                == StatusItem(
                    text: "Bambuddy not set up", symbol: .symbol("server.rack"), tint: .orange, action: .settings,
                    detail: notConfigured.message
                )
        )
        let rejected = BambuddyState.refused(.unauthorized)
        #expect(
            rejected.statusItem()
                == StatusItem(
                    text: "Bambuddy rejected the API key", symbol: .symbol("lock.trianglebadge.exclamationmark"),
                    tint: .red, action: .settings, detail: rejected.message
                )
        )
    }

    @Test func missingColourNamesWarnOnlyWhenReady() {
        let problem = "Colour names unavailable: timed out"
        #expect(
            BambuddyState.ready.statusItem(colorNamesProblem: problem)
                == StatusItem(
                    text: "Bambuddy ready \u{00B7} colour names unavailable", symbol: .symbol("paintpalette"),
                    tint: .orange, detail: problem, short: "Colour names unavailable"
                )
        )
        #expect(BambuddyState.unchecked.statusItem(colorNamesProblem: problem).text == "Bambuddy \u{00B7} not checked")
    }

    @Test func aCheckUnderWaySpins() {
        let checking = StatusItem(text: "Checking Bambuddy\u{2026}", symbol: .progress, tint: .gray)
        #expect(BambuddyState.unchecked.statusItem(isChecking: true) == checking)
        #expect(BambuddyState.refused(.spoolmanMode).statusItem(isChecking: true) == checking)
    }

    @Test func actionTitles() {
        #expect(StatusItem.Action.connect.title == "Connect")
        #expect(StatusItem.Action.check.title == "Check")
        #expect(StatusItem.Action.retry.title == "Retry")
        #expect(StatusItem.Action.settings.title == "Settings")
    }

    // MARK: Feed

    @Test func onlySpoolmanModeBlocksTheFeed() {
        let model = FeedViewModel(session: Session(settings: testSettings, inventory: nil), settings: testSettings)
        let states: [BambuddyState] = [
            .unchecked, .notConfigured, .ready, .unreachable("x"),
            .refused(.permissionMissing("inventory:read")), .refused(.unauthorized),
        ]
        for state in states {
            model.apply(SessionSnapshot(rows: [], bambuddy: state))
            #expect(!model.isBlocked, "\(state)")
        }
        model.apply(SessionSnapshot(rows: [], bambuddy: .refused(.spoolmanMode)))
        #expect(model.isBlocked)
    }

    @Test func theFeedCarriesTheBambuddyItem() {
        let model = FeedViewModel(session: Session(settings: testSettings, inventory: nil), settings: testSettings)
        model.apply(SessionSnapshot(rows: [], bambuddy: .ready, colorNamesProblem: "Colour names unavailable: x"))
        #expect(model.bambuddyStatus.symbol == .symbol("paintpalette"))
        model.apply(SessionSnapshot(rows: [], bambuddy: .ready, isCheckingBambuddy: true))
        #expect(model.bambuddyStatus.symbol == .progress)
    }
}

@MainActor
@Suite("Status bar actions")
struct StatusActionTests {
    private func makeHost(_ inventory: FakeInventory) throws -> HostModel {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        var settings = testSettings
        settings.transport = .usb
        try store.save(settings)
        return HostModel(
            store: store, makeInventory: { _ in inventory }, makeTransport: { _ in FakeTransport() },
            discoverPorts: { ["/dev/cu.usbmodemflip_A"] }
        )
    }

    @Test func aCheckUnderWayIsInTheSnapshot() async throws {
        let inventory = FakeInventory()
        inventory.spoolmanDelay = .milliseconds(200)
        let session = Session(settings: testSettings, inventory: inventory)
        #expect(await session.snapshot.isCheckingBambuddy == false)

        let check = Task { await session.checkBambuddy() }
        #expect(await eventually { await session.snapshot.isCheckingBambuddy })
        _ = await check.value

        #expect(await session.snapshot.isCheckingBambuddy == false)
        #expect(await session.snapshot.bambuddy == .ready)
    }

    @Test func retryRunsTheStartupCheckAgain() async throws {
        let inventory = FakeInventory()
        inventory.spoolman = true
        let host = try makeHost(inventory)
        #expect(await host.session.checkBambuddy() == .refused(.spoolmanMode))

        inventory.spoolman = false
        await host.perform(.retry)

        #expect(await host.session.bambuddy == .ready)
        #expect(inventory.calls.filter { $0 == .spoolman }.count == 2)
    }

    @Test func checkRunsTheStartupCheck() async throws {
        let inventory = FakeInventory()
        let host = try makeHost(inventory)

        await host.perform(.check)

        #expect(await host.session.bambuddy == .ready)
        #expect(inventory.calls.filter { $0 == .spoolman }.count == 1)
    }

    @Test func connectStartsTheLinkWithTheSavedChoice() async throws {
        let host = try makeHost(FakeInventory())
        #expect(!host.link.isActive)

        await host.perform(.connect)
        defer { host.link.disconnect() }

        #expect(host.link.isActive)
        #expect(host.link.choice == .usb(port: nil))
    }

    @Test func settingsIsLeftToTheView() async throws {
        let inventory = FakeInventory()
        let host = try makeHost(inventory)

        await host.perform(.settings)

        #expect(inventory.calls.isEmpty)
        #expect(!host.link.isActive)
    }

    @Test func anHTTPAddressAndAnUntrustedCertificateHaveTheirOwnLines() {
        #expect(
            BambuddyState.needsHTTPS.statusItem() == StatusItem(
                text: "Bambuddy needs HTTPS", symbol: .symbol("lock.slash"), tint: .red, action: .settings,
                detail: "FliBuddy needs an https:// address."
            )
        )
        #expect(
            BambuddyState.untrustedCertificate.statusItem() == StatusItem(
                text: "Bambuddy's certificate is not trusted", symbol: .symbol("lock.trianglebadge.exclamationmark"),
                tint: .red, action: .retry,
                detail: "This device does not trust the certificate Bambuddy uses for https://.",
                short: "Certificate not trusted"
            )
        )
        #expect(BambuddyState.needsHTTPS.flipperLines == ["Bambuddy needs", "HTTPS"])
        #expect(BambuddyState.untrustedCertificate.flipperLines == ["Certificate", "not trusted"])
    }
}
