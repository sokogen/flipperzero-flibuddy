import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// Bambuddy, new-item and weighing settings, and the Flipper transport: the
/// USB port (macOS only) or the Bluetooth Flipper. The Mac form has Save and
/// Revert; the iPhone and iPad form applies each change as it is made (the
/// model's `appliesOnChange`).
public struct SettingsForm: View {
    @Bindable var model: SettingsViewModel
    #if os(iOS)
    /// The text field being edited; leaving it commits it.
    @FocusState private var editing: TextFieldID?

    enum TextFieldID: Hashable {
        case url, apiKey, coreWeight
    }

    /// Read again on appear and when the app returns from Settings.
    @ViewState private var camera = CameraAccess.unsupported
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// The iPad caps the form at 640 and centres it; the iPhone's is full width.
    @Environment(\.feedLayout) private var layout
    @ViewState private var formWidth: CGFloat = 0
    #endif

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        #if os(iOS)
        phoneForm
        #else
        macForm
        #endif
    }

    #if os(iOS)
    /// The iPhone form (iOS spec, "Settings"): no Save row; pickers apply at
    /// once, text fields on Return or when they lose focus.
    private var phoneForm: some View {
        Form {
            Section {
                Button("Scan QR code", systemImage: "qrcode.viewfinder") {
                    editing = nil
                    Task { await scanQRCode() }
                }
                .disabled(!camera.canScan)
                if camera.offersOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                }
                LabeledContent("URL") {
                    TextField("URL", text: $model.baseURL, prompt: Text(verbatim: "https://bambuddy.example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .focused($editing, equals: .url)
                        .submitLabel(.done)
                }
                if let error = model.urlError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("API key") {
                    SecureField("API key", text: $model.apiKey, prompt: Text("bb_…"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .focused($editing, equals: .apiKey)
                        .submitLabel(.done)
                }
                // The result beside the button where both fit, else under it
                // (accessibility text sizes).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        testButton
                        Spacer()
                        resultLine(model.connectionResult).font(.subheadline)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        testButton
                        resultLine(model.connectionResult).font(.subheadline)
                    }
                }
            } header: {
                Text("Bambuddy")
            } footer: {
                let footer = SettingsViewModel.qrFooter(camera: camera, status: model.qrStatus)
                Text(footer.text).foregroundStyle(footer.tint == .gray ? .secondary : footer.tint.color)
            }
            Section {
                catalogPicker
                LabeledContent("Core weight") {
                    HStack(spacing: 4) {
                        TextField("Core weight", text: $model.coreWeightText)
                            .labelsHidden()
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($editing, equals: .coreWeight)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                // The catalog loads when Settings opens (SettingsScreen); no Reload.
                newItemErrors
            } header: {
                Text("New items")
            } footer: {
                Text("Weight of everything that is not filament; 242 g = Bambu reusable spool 215 g + refill core 27 g.")
            }
            Section {
                Picker("Type weight as", selection: $model.defaultMode) {
                    Text("Net").tag(Intent.WeightMode.net)
                    Text("Gross").tag(Intent.WeightMode.gross)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Weighing")
            } footer: {
                Text("Gross is the whole spool on the scale. Each row can still switch.")
            }
            Section {
                LabeledContent {
                    resultLine(model.flipperRowState)
                } label: {
                    Text(model.flipperRowTitle)
                }
                Button(model.isScanning ? "Stop scanning" : "Scan for Flipper") {
                    if model.isScanning { model.stopScanning() } else { model.scanForFlippers() }
                }
                if let problem = model.scanProblem {
                    Text(problem).foregroundStyle(.red)
                }
                discoveredFlippers
            } header: {
                Text("Flipper")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SettingsViewModel.flipperFooter(isPad: UIDevice.current.userInterfaceIdiom == .pad))
                    // Only on an iPhone with a paired watch.
                    if let watch = model.watchSyncText {
                        Text(watch)
                    }
                }
            }
            if let error = model.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            // Its own section, centred, as the iPhone and iPad pages draw it.
            Section {
                Button(role: .destructive) {
                    model.forget()
                } label: {
                    Text("Forget This Flipper").frame(maxWidth: .infinity)
                }
                .disabled(!model.canForget)
            }
            // The privacy policy and support pages, and the log for a bug
            // report (it holds no API key, QR or sync payload).
            Section {
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                Link("Support", destination: AppLinks.support)
                if let log = Log.fileURL {
                    ShareLink("Share Log", item: log)
                }
            } footer: {
                Text(SettingsViewModel.appVersionFooter)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .environment(\.defaultMinListRowHeight, 52)
        .modifier(PadFormWidth(isPad: layout.showsTiles, width: formWidth))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { formWidth = $0 }
        .onAppear { camera = CameraQRScanner.access }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera = CameraQRScanner.access }
        }
        // Return, or another field or control taking the focus, commits the field.
        .onSubmit { model.commit() }
        .onChange(of: editing) { old, _ in
            if old != nil { model.commit() }
        }
        // Leaving Settings commits and stops a scan, and the QR cover hangs
        // off the app's root (`settingsSession`): an iPad rotation builds
        // this form again, which must not stop either.
    }
    private var testButton: some View {
        Button("Test connection") {
            editing = nil
            Task { await model.testConnection() }
        }
        .disabled(model.connection == .testing)
    }

    /// The camera is asked for on the first Scan, not before.
    private func scanQRCode() async {
        if camera == .notDetermined {
            let granted = await CameraQRScanner.requestAccess()
            camera = CameraQRScanner.access
            guard granted else { return }
        }
        await model.scanQRCode(with: model.qrCover)
    }
    #else
    private var macForm: some View {
        Form {
            Section("Bambuddy") {
                TextField("Server URL", text: $model.baseURL, prompt: Text("http://192.168.1.20:8000"))
                SecureField("API key", text: $model.apiKey, prompt: Text("bb_…"))
                HStack(spacing: 8) {
                    Button("Test connection") {
                        Task { await model.testConnection() }
                    }
                    .disabled(model.connection == .testing)
                    resultLine(model.connectionResult)
                }
            }
            Section {
                catalogPicker
                LabeledContent("Core weight") {
                    HStack(spacing: 4) {
                        TextField("Core weight", value: $model.coreWeight, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                newItemErrors
                Button("Reload catalog") {
                    Task { await model.loadCatalog() }
                }
            } header: {
                Text("New items")
            } footer: {
                Text("Weight of everything that is not filament; 242 g = Bambu reusable spool 215 g + refill core 27 g.")
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
    }
    #endif

    private var catalogPicker: some View {
        Picker("Empty spool", selection: $model.catalogEntryId) {
            Text("None").tag(Int?.none)
            ForEach(model.catalog) { entry in
                Text("\(entry.name) (\(Grams.text(entry.weight)) g)").tag(Int?.some(entry.id))
            }
            if let id = model.catalogEntryId, !model.catalog.contains(where: { $0.id == id }) {
                Text("Entry #\(id)").tag(Int?.some(id))
            }
        }
    }

    @ViewBuilder private var newItemErrors: some View {
        if let error = model.coreWeightError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if let error = model.catalogError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
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
        discoveredFlippers
        Text("No pairing: the Flipper runs FliBuddy with Transport set to Bluetooth.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// The Flippers the scan found, a checkmark on the chosen one.
    private var discoveredFlippers: some View {
        ForEach(model.discovered) { peripheral in
            Button {
                model.choosePeripheral(peripheral)
            } label: {
                HStack {
                    Text(peripheral.name)
                    Spacer()
                    Text(WatchSettingsTexts.signal(rssi: peripheral.rssi)).foregroundStyle(.secondary)
                    if peripheral.id == model.peripheralId {
                        Image(systemName: "checkmark")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A test result: symbol (or spinner) and phrase, 4 pt apart.
    private func resultLine(_ item: StatusItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            StatusSymbolView(symbol: item.symbol, tint: item.tint)
            Text(item.text)
                .foregroundStyle(item.tint == .red ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
/// The iPad form's sections at most 640 wide, centred in a wider column
/// (iPad page); the iPhone keeps the system margins.
private struct PadFormWidth: ViewModifier {
    let isPad: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        if isPad {
            content.contentMargins(.horizontal, FeedLayout.settingsSideMargin(width: width), for: .scrollContent)
        } else {
            content
        }
    }
}

extension View {
    /// What of Settings must outlive its form, for the app's root view:
    /// the QR cover, and leaving (`showing` turning false) commits the field
    /// being typed and stops a Flipper scan (`SettingsViewModel.left()`).
    public func settingsSession(_ model: SettingsViewModel?, showing: Bool) -> some View {
        modifier(SettingsSession(model: model, showing: showing))
    }
}

private struct SettingsSession: ViewModifier {
    let model: SettingsViewModel?
    let showing: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: showing) { _, now in
                if !now { model?.left() }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { model?.qrCover.isPresenting ?? false },
                    set: { if !$0 { model?.qrCover.dismissed() } }
                ),
                // However the cover goes, a scan still open ends.
                onDismiss: { model?.qrCover.dismissed() }
            ) {
                if let model {
                    QRScannerCover(scanner: model.qrCover)
                }
            }
    }
}
#endif

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
