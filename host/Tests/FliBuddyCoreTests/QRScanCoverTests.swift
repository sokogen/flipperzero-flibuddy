import Testing
@testable import FliBuddyCore

@MainActor
@Suite("QR scan cover")
struct QRScanCoverTests {
    private static let qr = "bambuddy://config?v=1&url=https%3A%2F%2Fbambuddy.example.com&key=bb_from_qr"

    @Test func aScanRaisesTheCoverAndEndsWithWhatItRead() async throws {
        let cover = QRScanCover()
        let scan = Task { try await cover.scan() }
        #expect(await eventually { cover.isPresenting })

        cover.finish(.success("payload"))

        #expect(try await scan.value == "payload")
        #expect(!cover.isPresenting)
    }

    @Test func aCoverThatGoesAwayCancelsTheScan() async {
        // The presenter was torn down (dismissed, or rebuilt) with the scan open.
        let cover = QRScanCover()
        let scan = Task { try await cover.scan() }
        #expect(await eventually { cover.isPresenting })

        cover.dismissed()

        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(!cover.isPresenting)
        // Nothing left to resume: a second end is harmless.
        cover.dismissed()
        cover.finish(.success("late"))
    }

    @Test func theOldCoversDismissalDoesNotCancelANewScan() async throws {
        // The first cover is still animating away when a new scan raises it again;
        // the dismissal that follows belongs to the first scan.
        let cover = QRScanCover()
        let first = Task { try await cover.scan() }
        #expect(await eventually { cover.isPresenting })
        cover.finish(.success("first"))
        #expect(try await first.value == "first")
        let second = Task { try await cover.scan() }
        #expect(await eventually { cover.isPresenting })

        cover.dismissAnimationEnded()

        #expect(cover.isPresenting)
        cover.finish(.success("second"))
        #expect(try await second.value == "second")
    }

    @Test func aDismissalWithNothingPresentedIsHarmless() async {
        // Torn down with the cover already lowered: nothing open, harmless.
        let cover = QRScanCover()
        cover.dismissAnimationEnded()
        #expect(!cover.isPresenting)
    }

    @Test func aNewScanEndsTheOneBefore() async throws {
        let cover = QRScanCover()
        let first = Task { try await cover.scan() }
        #expect(await eventually { cover.isPresenting })
        let second = Task { try await cover.scan() }

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await eventually { cover.isPresenting })
        cover.finish(.success("second"))
        #expect(try await second.value == "second")
    }

    @Test func theSettingsModelOwnsItsCover() async {
        // The model outlives a rebuilt form (an iPad rotation), so the cover does too.
        let model = SettingsViewModel(
            settings: Settings(), makeInventory: { _ in FakeInventory() }, requiresHTTPS: false, apply: { _ in }
        )
        let scan = Task { await model.scanQRCode(with: model.qrCover) }
        #expect(await eventually { model.qrCover.isPresenting })

        model.qrCover.finish(.success(Self.qr))
        await scan.value

        #expect(model.baseURL == "https://bambuddy.example.com")
        #expect(model.apiKey == "bb_from_qr")
        #expect(!model.qrCover.isPresenting)
    }

    @Test func aDismissedCoverLeavesTheFieldsAndNoError() async {
        let model = SettingsViewModel(settings: testSettings, makeInventory: { _ in FakeInventory() }, apply: { _ in })
        let scan = Task { await model.scanQRCode(with: model.qrCover) }
        #expect(await eventually { model.qrCover.isPresenting })

        model.qrCover.dismissed()
        await scan.value

        #expect(model.qrStatus == nil)
        #expect(model.baseURL == testSettings.baseURL)
    }
}
