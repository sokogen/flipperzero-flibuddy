import Foundation
import Observation

/// The QR scanner's full-screen cover as a `QRScanning`: `scan()` raises
/// `isPresenting` and waits; the cover ends it with `finish(_:)` (the code
/// it read, or an error) or `dismissed()` when it goes away. The scan always
/// ends: a new scan, or the cover going away for any reason, cancels the one
/// still open. `SettingsViewModel` owns one, so it outlives a Settings form
/// that is built again (an iPad rotation).
@MainActor
@Observable
public final class QRScanCover: QRScanning {
    public var isPresenting = false
    @ObservationIgnored private var continuation: CheckedContinuation<String, any Error>?

    public init() {}

    public func scan() async throws -> String {
        finish(.failure(CancellationError()))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            isPresenting = true
        }
    }

    /// Ends the open scan, if any, and lowers the cover.
    public func finish(_ result: Result<String, any Error>) {
        isPresenting = false
        continuation?.resume(with: result)
        continuation = nil
    }

    /// The cover went away (closed, swiped down, or its presenter torn
    /// down): a scan still open ends as cancelled.
    public func dismissed() {
        guard continuation != nil else {
            isPresenting = false
            return
        }
        Log.debug(.settings, "qr: cover went away, scan cancelled")
        finish(.failure(CancellationError()))
    }
}
