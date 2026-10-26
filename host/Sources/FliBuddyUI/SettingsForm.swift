import FliBuddyCore
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
                TextField("Server URL", text: $model.baseURL, prompt: Text("http://192.168.1.20:8000"))
                SecureField("API key", text: $model.apiKey, prompt: Text("bb_…"))
                #if os(iOS)
                if CameraQRScanner.isAvailable {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") {
                        Task { await model.scanQRCode(with: qrScanner) }
                    }
                }
                #endif
                qrStatus
                HStack(spacing: 8) {
                    Button("Test connection") {
                        Task { await model.testConnection() }
                    }
                    .disabled(model.connection == .testing)
                    resultLine(model.connectionResult)
                }
            }
            Section {
                Picker("Empty spool", selection: $model.catalogEntryId) {
                    Text("None").tag(Int?.none)
                    ForEach(model.catalog) { entry in
                        Text("\(entry.name) (\(entry.weight) g)").tag(Int?.some(entry.id))
                    }
                    if let id = model.catalogEntryId, !model.catalog.contains(where: { $0.id == id }) {
                        Text("Entry #\(id)").tag(Int?.some(id))
                    }
                }
                LabeledContent("Core weight") {
                    HStack(spacing: 4) {
                        TextField("Core weight", value: $model.coreWeight, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                if let error = model.coreWeightError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let error = model.catalogError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Reload catalog") {
                    Task { await model.loadCatalog() }
                }
            } header: {
                Text("New items")
            } footer: {
                Text("Weight of everything that is not filament; 325 g = Bambu reusable spool 293 g + refill core 32 g.")
            }
            Section {
                Picker("I type the weight as", selection: $model.defaultMode) {
                    Text("Net").tag(Intent.WeightMode.net)
                    Text("Gross").tag(Intent.WeightMode.gross)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Weighing")
            } footer: {
                Text("Gross is the whole spool on the scale. Each row can still switch.")
            }
            Section("Flipper") {
                if model.availableTransports.count > 1 {
                    Picker("Connection", selection: $model.transport) {
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
                HStack {
                    Text(model.connectionLine).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget", role: .destructive) { model.forget() }
                        .disabled(!model.canForget)
                }
            }
            Section {
                if let error = model.saveError {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Text(model.saveStatusText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") { model.revert() }
                        .disabled(!model.canRevert)
                    Button("Save") {
                        Task { await model.save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
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

    /// The chosen Flipper and the scan with its results.
    @ViewBuilder private var bluetooth: some View {
        LabeledContent("Flipper", value: model.bluetoothFlipperText)
        HStack {
            Button(model.isScanning ? "Stop scanning" : "Scan for Flipper") {
                if model.isScanning { model.stopScanning() } else { model.scanForFlippers() }
            }
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
        }
        if let problem = model.scanProblem {
            Text(problem).foregroundStyle(.red)
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
        Text("No pairing: the Flipper runs FliBuddy with Transport set to Bluetooth.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var qrStatus: some View {
        switch model.qrStatus {
        case nil: EmptyView()
        case .applied(let message): Label(message, systemImage: "qrcode").font(.caption).foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
        }
    }

    /// A test result: symbol (or spinner) and phrase, 4 pt apart.
    private func resultLine(_ item: StatusItem) -> some View {
        HStack(spacing: 4) {
            StatusSymbolView(symbol: item.symbol, tint: item.tint)
            Text(item.text).foregroundStyle(item.tint == .red ? .red : .secondary)
        }
        .accessibilityElement(children: .combine)
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
