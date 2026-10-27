#if os(iOS)
import FliBuddyCore
import SwiftUI
import VisionKit

/// Scans a QR code with VisionKit's `DataScannerViewController` in a
/// full-screen cover. `scan()` raises `isPresenting`; the cover ends the scan
/// with the first QR code it reads, or with `CancellationError` when it is
/// closed.
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

    /// Ends the running scan, if any, and closes the cover.
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

/// The full-screen cover: the camera edge to edge, close at the top leading
/// corner, a corner-bracket frame in the middle and the hint under it.
struct QRScannerCover: View {
    let scanner: CameraQRScanner

    var body: some View {
        ZStack {
            QRScannerView(
                onScan: { scanner.finish(.success($0)) },
                onFailure: { scanner.finish(.failure($0)) }
            )
            .ignoresSafeArea()
            VStack(spacing: 24) {
                ScanBrackets()
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: 240, height: 240)
                    .accessibilityHidden(true)
                Text("Point at the QR code Bambuddy shows when you create an API key.")
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.horizontal, 32)
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Close", systemImage: "xmark") { scanner.finish(.failure(CancellationError())) }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: .circle)
                .padding(16)
        }
    }
}

/// Four corner brackets of a square viewfinder.
private struct ScanBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.2
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
            (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}
#endif
