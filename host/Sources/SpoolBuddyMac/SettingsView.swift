import SpoolBuddyCore
import SwiftUI

/// The Settings window. Each time it opens it edits a fresh copy of the saved settings.
struct SettingsView: View {
    let host: HostModel
    @ViewState private var model: SettingsViewModel?

    var body: some View {
        Group {
            if let model {
                SettingsForm(model: model)
            } else {
                ProgressView()
            }
        }
        // The window takes its size from the content; give the placeholder
        // the form's size so the saved window frame never shrinks to the spinner.
        .frame(width: 640)
        .frame(minHeight: 600)
        .onAppear {
            let model = host.makeSettingsViewModel()
            model.refreshPorts()
            self.model = model
            Task { await model.loadCatalog() }
        }
    }
}

struct SettingsForm: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Form {
            Section("Bambuddy") {
                TextField("URL", text: $model.baseURL, prompt: Text("http://192.168.1.20:8000"))
                SecureField("API key", text: $model.apiKey, prompt: Text("bb_…"))
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
                Picker("Port", selection: $model.port) {
                    Text("Automatic").tag(String?.none)
                    ForEach(model.ports, id: \.self) { port in
                        Text(port).tag(String?.some(port))
                    }
                }
                Button("Refresh ports") { model.refreshPorts() }
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
