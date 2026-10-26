import SpoolBuddyCore
import SwiftUI

#if os(watchOS)
/// Settings on the watch: what arrived from the iPhone, read-only, and the
/// Flipper, which the watch picks itself with "Scan for Flipper".
public struct WatchSettingsView: View {
    let host: HostModel
    let receiver: WatchSettingsReceiver?
    @ViewState private var scanner: SettingsViewModel?
    @ViewState private var chooseError: String?

    public init(host: HostModel, receiver: WatchSettingsReceiver?) {
        self.host = host
        self.receiver = receiver
    }

    public var body: some View {
        let settings = host.settings
        List {
            Section("From iPhone") {
                if settings.baseURL.isEmpty && settings.apiKey.isEmpty {
                    Text("Open SpoolBuddy on the iPhone and save its settings.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Bambuddy", value: settings.baseURL.isEmpty ? "Not set" : settings.baseURL)
                    LabeledContent("API key", value: settings.apiKey.isEmpty ? "Missing" : "Set")
                    LabeledContent("Core", value: "\(settings.coreWeight) g")
                    LabeledContent("Weight", value: settings.defaultMode == .gross ? "Gross" : "Net")
                }
                if let error = receiver?.lastError {
                    Text(error).foregroundStyle(.red)
                }
                Text(host.feed.bambuddy.statusText).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Flipper") {
                LabeledContent("Flipper", value: settings.peripheralName ?? "First found")
                Text(host.link.statusText).font(.footnote).foregroundStyle(.secondary)
                if let scanner {
                    if scanner.isScanning {
                        Button("Stop scanning") { scanner.stopScanning() }
                    } else {
                        Button("Scan for Flipper") { scanner.scanForFlippers() }
                    }
                    if let problem = scanner.scanProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                    ForEach(scanner.discovered) { peripheral in
                        Button {
                            choose(peripheral)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(peripheral.name)
                                Text("\(peripheral.rssi) dBm").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let chooseError {
                    Text(chooseError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            if scanner == nil { scanner = host.makeSettingsViewModel() }
        }
        .onDisappear { scanner?.stopScanning() }
    }

    private func choose(_ peripheral: DiscoveredPeripheral) {
        scanner?.stopScanning()
        Task {
            do {
                try await host.useFlipper(peripheral)
                chooseError = nil
            } catch {
                chooseError = error.localizedDescription
            }
        }
    }
}
#endif
