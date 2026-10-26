import SpoolBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// Bambuddy, new-item and weighing settings, and the Flipper transport: the
/// USB port (macOS only) or the Bluetooth Flipper.
public struct SettingsForm: View {
    @Bindable var model: SettingsViewModel
    #if os(iOS)
    @ViewState private var qrScanner = CameraQRScanner()
    #endif

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Bambuddy") {
                TextField("URL", text: $model.baseURL, prompt: Text("http://192.168.1.20:8000"))
                SecureField("API key", text: $model.apiKey, prompt: Text("bb_…"))
                #if os(iOS)
                if CameraQRScanner.isAvailable {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") {
                        Task { await model.scanQRCode(with: qrScanner) }
                    }
                }
                #endif
                qrStatus
                HStack {
                    Button("Test connection") {
                        Task { await model.testConnection() }
                    }
                    connectionStatus
                }
            }
            Section("New items") {
                Picker("Empty spool", selection: $model.catalogEntryId) {
                    Text("None").tag(Int?.none)
                    ForEach(model.catalog) { entry in
                        Text("\(entry.name) (\(entry.weight) g)").tag(Int?.some(entry.id))
                    }
                    if let id = model.catalogEntryId, !model.catalog.contains(where: { $0.id == id }) {
                        Text("Entry #\(id)").tag(Int?.some(id))
                    }
                }
                TextField("Core weight (g)", value: $model.coreWeight, format: .number)
                Text("Weight of everything that is not filament; 325 g = Bambu reusable spool 293 g + refill core 32 g.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.coreWeightError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let error = model.catalogError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Reload catalog") {
                    Task { await model.loadCatalog() }
                }
            }
            Section("Weighing") {
                Picker("Default mode", selection: $model.defaultMode) {
                    Text("Net").tag(Intent.WeightMode.net)
                    Text("Gross").tag(Intent.WeightMode.gross)
                }
                .pickerStyle(.segmented)
            }
            Section("Flipper") {
                if model.availableTransports.count > 1 {
                    Picker("Transport", selection: $model.transport) {
                        ForEach(model.availableTransports, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if model.transport == .usb, model.showsUSB {
                    Picker("Port", selection: $model.port) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.ports, id: \.self) { port in
                            Text(port).tag(String?.some(port))
                        }
                    }
                    Button("Refresh ports") { model.refreshPorts() }
                } else {
                    bluetooth
                }
            }
            Section {
                HStack {
                    if let error = model.saveError {
                        Text(error).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Save") {
                        Task { await model.save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.stopScanning() }
        #if os(iOS)
        .sheet(isPresented: $qrScanner.isPresenting, onDismiss: { qrScanner.finish(.failure(CancellationError())) }) {
            QRScannerSheet(scanner: qrScanner)
        }
        #endif
    }

    /// The remembered Flipper, Forget, and the scan with its results.
    @ViewBuilder private var bluetooth: some View {
        LabeledContent("Flipper", value: model.peripheralName ?? "First found")
        if model.peripheralId != nil {
            Button("Forget Flipper") { model.forgetPeripheral() }
        }
        HStack {
            Button(model.isScanning ? "Stop scanning" : "Scan for Flipper") {
                if model.isScanning { model.stopScanning() } else { model.scanForFlippers() }
            }
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
        }
        ForEach(model.discovered) { peripheral in
            Button {
                model.choosePeripheral(peripheral)
            } label: {
                HStack {
                    Text(peripheral.name)
                    Spacer()
                    Text("\(peripheral.rssi) dBm").foregroundStyle(.secondary)
                    if peripheral.id == model.peripheralId {
                        Image(systemName: "checkmark")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        Text("No pairing: the Flipper runs SpoolBuddy with Transport set to Bluetooth.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var qrStatus: some View {
        switch model.qrStatus {
        case nil: EmptyView()
        case .applied(let message): Label(message, systemImage: "qrcode").font(.caption).foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch model.connection {
        case nil: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let message): Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

extension TransportKind {
    /// The picker label.
    var title: String {
        switch self {
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        }
    }
}
#endif
