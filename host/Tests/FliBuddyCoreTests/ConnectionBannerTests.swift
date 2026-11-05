import Foundation
import Testing
@testable import FliBuddyCore

@MainActor
@Suite("iPhone connection banner")
struct ConnectionBannerTests {
    private static let fap = Hello(app: "flibuddy-fap/0.1.0", fw: "1.5.1")
    private static let bluetooth = TransportChoice.bluetooth(peripheral: nil)

    private func flipper(_ state: LinkState, problem: String? = nil, isActive: Bool = true) -> StatusItem {
        FlipperLink.statusItem(state, choice: Self.bluetooth, port: nil, problem: problem, isActive: isActive)
    }

    private var connected: StatusItem { flipper(.connected(Self.fap)) }
    private var ready: StatusItem { BambuddyState.ready.statusItem() }

    /// The one line the banner shows when only `item`'s side is in trouble.
    private func line(flipper item: StatusItem) -> StatusItem? {
        let banner = ConnectionBanner(flipper: item, bambuddy: ready)
        #expect(banner.lines.count == 1)
        return banner.lines.first
    }

    private func line(bambuddy item: StatusItem) -> StatusItem? {
        let banner = ConnectionBanner(flipper: connected, bambuddy: item)
        #expect(banner.lines.count == 1)
        return banner.lines.first
    }

    @Test func bothSidesHealthyIsOneGreenLine() {
        let banner = ConnectionBanner(flipper: connected, bambuddy: ready)
        #expect(
            banner.lines == [
                StatusItem(
                    text: "Flipper connected \u{00B7} Bambuddy ready", symbol: .symbol("checkmark.circle.fill"),
                    tint: .green, detail: "firmware 1.5.1"
                ),
            ]
        )
        #expect(!banner.isTwoLines)
    }

    // MARK: Flipper phrases

    @Test func searchingSpins() {
        #expect(
            line(flipper: flipper(.disconnected))
                == StatusItem(text: "No Flipper \u{00B7} searching", symbol: .progress, tint: .gray)
        )
        #expect(line(flipper: flipper(.waitingForHello))?.text == "No Flipper \u{00B7} searching")
    }

    @Test func aStoppedLinkIsNotConnectedWithSettings() {
        #expect(
            line(flipper: flipper(.disconnected, isActive: false))
                == StatusItem(
                    text: "Flipper not connected", symbol: .symbol("antenna.radiowaves.left.and.right"), tint: .orange,
                    action: .settings, isSetupStep: true
                )
        )
    }

    @Test func noHelloAsksToOpenTheApp() {
        #expect(
            line(flipper: flipper(.noAnswer))
                == StatusItem(text: "Open FliBuddy on the Flipper", symbol: .symbol("app.dashed"), tint: .orange)
        )
    }

    @Test func linkProblemsAndVersionMismatchKeepTheMacPhrases() {
        #expect(
            line(flipper: flipper(.disconnected, problem: "Bluetooth is off"))
                == StatusItem(
                    text: "Bluetooth is off", symbol: .symbol("antenna.radiowaves.left.and.right.slash"),
                    tint: .orange, detail: "Bluetooth is off"
                )
        )
        #expect(line(flipper: flipper(.otherVersion(1))) == flipper(.otherVersion(1)))
    }

    // MARK: Bambuddy phrases

    @Test func uncheckedOffersCheck() {
        #expect(
            line(bambuddy: BambuddyState.unchecked.statusItem())
                == StatusItem(text: "Bambuddy not checked", symbol: .symbol("server.rack"), tint: .gray, action: .check)
        )
    }

    @Test func unreachableOffersRetry() {
        #expect(
            line(bambuddy: BambuddyState.unreachable("Bambuddy unreachable: timed out").statusItem())
                == StatusItem(
                    text: "Bambuddy unreachable", symbol: .symbol("wifi.exclamationmark"), tint: .red,
                    action: .retry, detail: "Bambuddy unreachable: timed out"
                )
        )
    }

    @Test func aKeyWithoutPermissionOffersSettings() {
        let state = BambuddyState.refused(.permissionMissing("inventory:read"))
        #expect(
            line(bambuddy: state.statusItem())
                == StatusItem(
                    text: "Key lacks inventory permission", symbol: .symbol("lock.trianglebadge.exclamationmark"),
                    tint: .red, action: .settings, detail: state.message
                )
        )
    }

    @Test func spoolmanModeOffersRetry() {
        let state = BambuddyState.refused(.spoolmanMode)
        #expect(
            line(bambuddy: state.statusItem())
                == StatusItem(
                    text: "Bambuddy is in Spoolman mode", symbol: .symbol("nosign"), tint: .red, action: .retry,
                    detail: state.message
                )
        )
    }

    @Test func missingColourNamesIsAnOrangeLine() {
        let problem = "Color names unavailable: timed out"
        #expect(
            line(bambuddy: BambuddyState.ready.statusItem(colorNamesProblem: problem))
                == StatusItem(
                    text: "Color names unavailable", symbol: .symbol("paintpalette"), tint: .orange, detail: problem
                )
        )
    }

    @Test func statesBeyondTheTableKeepTheMacPhrases() {
        for item in [
            BambuddyState.notConfigured.statusItem(),
            BambuddyState.refused(.unauthorized).statusItem(),
            BambuddyState.unchecked.statusItem(isChecking: true),
        ] {
            #expect(line(bambuddy: item) == item)
        }
        #expect(line(bambuddy: BambuddyState.notConfigured.statusItem())?.action == .settings)
        #expect(line(bambuddy: BambuddyState.refused(.unauthorized).statusItem())?.action == .settings)
        #expect(line(bambuddy: BambuddyState.unchecked.statusItem(isChecking: true))?.symbol == .progress)
    }

    // MARK: Both sides

    @Test func bothSidesDownAreTwoLinesFlipperFirst() {
        let banner = ConnectionBanner(
            flipper: flipper(.disconnected, isActive: false),
            bambuddy: BambuddyState.unreachable("timed out").statusItem()
        )
        #expect(banner.isTwoLines)
        #expect(banner.lines.map(\.text) == ["Flipper not connected", "Bambuddy unreachable"])
        #expect(banner.lines.map(\.action) == [.settings, .retry])
    }

    @Test func theHostModelBuildsItsBanner() {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        let model = HostModel(store: store, makeInventory: { _ in FakeInventory() }, makeTransport: { _ in FakeTransport() })
        #expect(
            model.connectionBanner
                == ConnectionBanner(
                    flipper: model.link.statusItem, bambuddy: model.feed.bambuddyStatus,
                    emptyState: model.feedEmptyState
                )
        )
        // The empty feed asks for Bambuddy; the Flipper's Settings line waits.
        #expect(model.feedEmptyState == .noServer)
        #expect(model.connectionBanner.lines.map(\.action) == [.check])
    }
}
