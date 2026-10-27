import FliBuddyCore
import SwiftUI

#if os(watchOS)
/// Settings on the watch, read-only: what arrived from the iPhone, and the
/// Flipper, which the watch picks itself on the Scan for Flipper screen.
public struct WatchSettingsView: View {
    let host: HostModel
    let receiver: WatchSettingsReceiver?
    let onScan: () -> Void

    public init(host: HostModel, receiver: WatchSettingsReceiver?, onScan: @escaping () -> Void) {
        self.host = host
        self.receiver = receiver
        self.onScan = onScan
    }

    public var body: some View {
        let settings = host.settings
        let flipper = WatchSettingsTexts.flipperStatus(host.link.statusItem)
        List {
            Section {
                if settings.baseURL.isEmpty && settings.apiKey.isEmpty {
                    Text(WatchSettingsTexts.emptyText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    WatchSettingPlatter(label: "Server", value: WatchSettingsTexts.server(settings.baseURL))
                    WatchSettingPlatter(label: "Core weight", value: WatchSettingsTexts.coreWeight(settings.coreWeight))
                    WatchSettingPlatter(label: "Weight as", value: WatchSettingsTexts.mode(settings.defaultMode))
                }
                if let error = receiver?.lastError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(StatusTint.red.watchColor)
                }
            } header: {
                Text("From iPhone").font(.system(size: 12))
            } footer: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(WatchSettingsTexts.footer(received: receiver?.lastReceived, now: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WatchSettingsTexts.flipperName(settings.peripheralName)).font(.system(size: 15))
                    HStack(spacing: 4) {
                        switch flipper.symbol {
                        case .progress:
                            ProgressView().frame(width: 12, height: 12)
                        case .symbol(let name):
                            Image(systemName: name).font(.system(size: 12))
                        }
                        Text(flipper.text).font(.system(size: 13))
                    }
                    .foregroundStyle(flipper.tint.watchColor)
                }
                .padding(.vertical, 8)
                .listRowBackground(WatchPlatter())
                .accessibilityElement(children: .combine)
                Button("Scan for Flipper", action: onScan)
                    .buttonStyle(WatchCapsuleButtonStyle(
                        fill: WatchPlatter.fill, foreground: StatusTint.blue.watchColor, height: 44, fontSize: 15
                    ))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Flipper").font(.system(size: 12))
            }
        }
        .navigationTitle("Settings")
    }
}

/// A 15 pt label over its 13 pt `.secondary` value, on the feed's platter.
struct WatchSettingPlatter: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 15))
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
        .listRowBackground(WatchPlatter())
        .accessibilityElement(children: .combine)
    }
}

/// Scan for Flipper: scans while it shows; a tap on a Flipper found makes it
/// the watch's Flipper and goes back to Settings (`onChosen`).
public struct WatchScanView: View {
    let host: HostModel
    let onChosen: () -> Void
    @ViewState private var scanner: SettingsViewModel?
    @ViewState private var chooseError: String?

    public init(host: HostModel, onChosen: @escaping () -> Void) {
        self.host = host
        self.onChosen = onChosen
    }

    public var body: some View {
        List {
            if let scanner {
                if scanner.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().frame(width: 12, height: 12)
                        Text("Searching\u{2026}")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Button("Scan again") { scanner.scanForFlippers() }
                        .buttonStyle(WatchCapsuleButtonStyle(
                            fill: WatchPlatter.fill, foreground: StatusTint.blue.watchColor, height: 44, fontSize: 15
                        ))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if let problem = scanner.scanProblem {
                    Text(problem)
                        .font(.system(size: 13))
                        .foregroundStyle(StatusTint.red.watchColor)
                        .listRowBackground(Color.clear)
                }
                ForEach(scanner.discovered) { peripheral in
                    Button { choose(peripheral) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 18))
                                .foregroundStyle(StatusTint.blue.watchColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peripheral.name).font(.system(size: 15))
                                Text(WatchSettingsTexts.signal(rssi: peripheral.rssi))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(WatchPlatter())
                }
            }
            if let chooseError {
                Text(chooseError)
                    .font(.system(size: 13))
                    .foregroundStyle(StatusTint.red.watchColor)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Scan for Flipper")
        .onAppear {
            if scanner == nil { scanner = host.makeSettingsViewModel() }
            scanner?.scanForFlippers()
        }
        .onDisappear { scanner?.stopScanning() }
    }

    private func choose(_ peripheral: DiscoveredPeripheral) {
        scanner?.stopScanning()
        Task {
            do {
                try await host.useFlipper(peripheral)
                chooseError = nil
                onChosen()
            } catch {
                chooseError = error.localizedDescription
            }
        }
    }
}
#endif
