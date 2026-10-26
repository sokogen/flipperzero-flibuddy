#if os(iOS)
import FliBuddyCore
import SwiftUI
import VisionKit

/// Scans a QR code with VisionKit's `DataScannerViewController` in a sheet.
/// `scan()` raises `isPresenting`; the sheet ends the scan with the first QR
/// code it reads, or with `CancellationError` when it is dismissed.
@MainActor
@Observable
final class CameraQRScanner: QRScanning {
    /// The camera scanner runs on this device and camera access is not denied.
    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var isPresenting = false
    private var continuation: CheckedContinuation<String, any Error>?

    func scan() async throws -> String {
        finish(.failure(CancellationError()))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            isPresenting = true
        }
    }

    /// Ends the running scan, if any, and closes the sheet.
    func finish(_ result: Result<String, any Error>) {
        isPresenting = false
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// The camera preview; reports the first QR code with a text payload.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (any Error) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            onFailure(error)
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: QRScannerView
        private var done = false

        init(parent: QRScannerView) {
            self.parent = parent
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue, !done else { continue }
                done = true
                dataScanner.stopScanning()
                parent.onScan(text)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !done else { return }
            done = true
            parent.onFailure(error)
        }
    }
}

/// The sheet: the camera with a hint and Cancel.
struct QRScannerSheet: View {
    let scanner: CameraQRScanner

    var body: some View {
        NavigationStack {
            QRScannerView(
                onScan: { scanner.finish(.success($0)) },
                onFailure: { scanner.finish(.failure($0)) }
            )
            .ignoresSafeArea()
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { scanner.finish(.failure(CancellationError())) }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("The QR code from Bambuddy's API key dialog").font(.footnote)
                }
            }
        }
    }
}
#endif
