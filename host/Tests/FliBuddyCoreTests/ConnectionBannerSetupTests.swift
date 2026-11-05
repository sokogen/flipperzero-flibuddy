import Foundation
import Testing
@testable import FliBuddyCore

@MainActor
@Suite("Banner chips read with their side")
struct BannerChipLabelTests {
    @Test func theBannerLinesKnowTheirSide() {
        let banner = ConnectionBanner(
            flipper: FlipperLink.statusItem(.disconnected, choice: nil, port: nil, problem: nil, isActive: false),
            bambuddy: BambuddyState.unreachable("timed out").statusItem()
        )
        #expect(banner.entries.map(\.actionLabel) == ["Flipper settings", "Retry Bambuddy"])
        #expect(banner.entries.map(\.item) == banner.lines)
    }

    @Test func theHealthyLineHasNoChip() {
        let banner = ConnectionBanner(
            flipper: FlipperLink.statusItem(
                .connected(Hello(app: "flibuddy-fap/1.0", fw: "1.5.1")), choice: .bluetooth(peripheral: nil),
                port: nil, problem: nil, isActive: true
            ),
            bambuddy: BambuddyState.ready.statusItem()
        )
        #expect(banner.entries.map(\.actionLabel) == [nil])
    }
}

@MainActor
@Suite("Banner beside a first-run empty feed")
struct BannerSetupStepTests {
    private var notStarted: StatusItem {
        FlipperLink.statusItem(.disconnected, choice: nil, port: nil, problem: nil, isActive: false)
    }

    private var searching: StatusItem {
        FlipperLink.statusItem(.disconnected, choice: .bluetooth(peripheral: nil), port: nil, problem: nil, isActive: true)
    }

    @Test func theSetupStatesAreSetupSteps() {
        #expect(notStarted.isSetupStep)
        #expect(BambuddyState.notConfigured.statusItem().isSetupStep)
        #expect(BambuddyState.needsHTTPS.statusItem().isSetupStep)
        #expect(!searching.isSetupStep)
        #expect(!BambuddyState.unreachable("x").statusItem().isSetupStep)
        #expect(!BambuddyState.unchecked.statusItem().isSetupStep)
        #expect(!BambuddyState.refused(.unauthorized).statusItem().isSetupStep)
    }

    @Test func aFirstRunShowsNoBannerUnderTheEmptyFeedsStep() {
        let banner = ConnectionBanner(
            flipper: notStarted, bambuddy: BambuddyState.notConfigured.statusItem(), emptyState: .noServer
        )
        #expect(banner.lines.isEmpty)
    }

    @Test func realProblemsStayBesideASetupStep() {
        let banner = ConnectionBanner(
            flipper: notStarted, bambuddy: BambuddyState.unreachable("timed out").statusItem(), emptyState: .noFlipper
        )
        #expect(banner.lines.map(\.text) == ["Bambuddy unreachable"])
        let searchingBanner = ConnectionBanner(
            flipper: searching, bambuddy: BambuddyState.notConfigured.statusItem(), emptyState: .noServer
        )
        #expect(searchingBanner.lines.map(\.text) == ["No Flipper \u{00B7} searching"])
    }

    @Test func withScansOrNoSetupStepTheBannerShowsEverything() {
        for state in [FeedEmptyState.noScans, nil] {
            let banner = ConnectionBanner(
                flipper: notStarted, bambuddy: BambuddyState.notConfigured.statusItem(), emptyState: state
            )
            #expect(banner.lines.map(\.text) == ["Flipper not connected", "Bambuddy not set up"])
        }
    }

    @Test func theSetupStepsAreTheMissingServerAndFlipper() {
        #expect(FeedEmptyState.noServer.isSetupStep)
        #expect(FeedEmptyState.needsHTTPS.isSetupStep)
        #expect(FeedEmptyState.noFlipper.isSetupStep)
        #expect(!FeedEmptyState.noScans.isSetupStep)
    }

    @Test func theHostModelHidesTheSetupLinesOfAnEmptyFeed() {
        let store = SettingsStore(defaults: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        let model = HostModel(
            store: store, makeInventory: { _ in FakeInventory() }, makeTransport: { _ in FakeTransport() },
            discoverPorts: { [] }, linkWaitsForChosenFlipper: true
        )
        #expect(model.feedEmptyState == .noServer)
        #expect(model.connectionBanner.lines.allSatisfy { !$0.isSetupStep })
        #expect(
            model.connectionBanner
                == ConnectionBanner(
                    flipper: model.link.statusItem, bambuddy: model.feed.bambuddyStatus, emptyState: .noServer
                )
        )
    }
}
