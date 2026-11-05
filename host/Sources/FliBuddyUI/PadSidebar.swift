import FliBuddyCore
import Observation
import SwiftUI

#if os(iOS)
/// The iPhone/iPad app's panes: the sidebar's selection on the iPad, the tabs
/// on the iPhone.
public enum AppPane: String, Hashable, Sendable {
    case feed, spools, settings
}

/// What the app's menu commands change: the pane on show and the Clear
/// confirmation, so ⌘, and ⌘⌫ reach whichever layout is on screen.
@MainActor
@Observable
public final class AppNavigation {
    public var pane: AppPane
    public var confirmingClear = false
    /// The empty feed's Scan for Flipper: Settings starts a scan when it
    /// shows, then clears this.
    public var scanRequested = false

    public init(pane: AppPane = .feed) {
        self.pane = pane
    }

    /// Opens Settings and has it scan for a Flipper; the Bluetooth
    /// permission prompt comes with that scan.
    public func scanForFlipper() {
        scanRequested = true
        pane = .settings
    }

    /// Shows the feed and asks before clearing it.
    public func requestClear() {
        pane = .feed
        confirmingClear = true
    }
}

private struct FeedLayoutKey: EnvironmentKey {
    static let defaultValue = FeedLayout.cards
}

extension EnvironmentValues {
    /// The iPad's sidebar or top tabs with tiles, or the iPhone's tabs and
    /// cards; `RootView` sets it from the window (`FeedLayout.forWindow`).
    public var feedLayout: FeedLayout {
        get { self[FeedLayoutKey.self] }
        set { self[FeedLayoutKey.self] = newValue }
    }
}

/// The hardware keyboard's commands, declared as menu commands so holding ⌘
/// lists them (ipados spec, "Keyboard and touch"): ⌘S, ⌘↑ / ⌘↓, ⌘⌫, ⌘,.
public struct FeedCommands: Commands {
    let host: HostModel
    let navigation: AppNavigation

    public init(host: HostModel, navigation: AppNavigation) {
        self.host = host
        self.navigation = navigation
    }

    public var body: some Commands {
        CommandMenu("Feed") {
            Button("Save Focused Row") { Task { await host.feed.saveFocused() } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Previous Row") { host.feed.moveFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Row") { host.feed.moveFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            // Checked on press: a command's state may not follow the feed.
            Button("Clear Feed\u{2026}") {
                guard !host.feed.items.isEmpty else { return }
                navigation.requestClear()
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { navigation.pane = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// The iPad sidebar: Connections with the Flipper and Bambuddy rows and
/// their action chips, Feed with its row count, Spools with the number of
/// active spools, Settings, and Clear feed at the bottom.
public struct PadSidebar: View {
    let host: HostModel
    @Bindable var navigation: AppNavigation

    public init(host: HostModel, navigation: AppNavigation) {
        self.host = host
        self.navigation = navigation
    }

    public var body: some View {
        let sidebar = host.sidebar
        List(selection: Binding<AppPane?>(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) {
            Section {
                PadStatusRow(row: sidebar.flipper, perform: perform)
                PadStatusRow(row: sidebar.bambuddy, perform: perform)
            } header: {
                Text(Sidebar.connectionsTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Section {
                Label("Feed", systemImage: "list.bullet")
                    .badge(sidebar.feedCount)
                    .tag(AppPane.feed)
                Label(SpoolsViewModel.title, systemImage: "shippingbox")
                    .badge(sidebar.spoolCount ?? 0)
                    .tag(AppPane.spools)
                HStack {
                    Label("Settings", systemImage: "gearshape")
                    Spacer()
                    Text(Sidebar.settingsHint)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .tag(AppPane.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("FliBuddy")
        // The Spools badge wants a count before the pane was opened. Not
        // `.task`: a cancelled load would read as Bambuddy unreachable.
        .onAppear { Task { await host.spools.loadIfNeeded() } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(role: .destructive) {
                navigation.requestClear()
            } label: {
                HStack {
                    Label(Sidebar.clearTitle, systemImage: "trash")
                    Spacer()
                    Text(Sidebar.clearHint)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.red)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!sidebar.canClear)
            .opacity(sidebar.canClear ? 1 : 0.4)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func perform(_ action: StatusItem.Action) {
        if action == .settings {
            navigation.pane = .settings
        } else {
            Task { await host.perform(action) }
        }
    }
}

/// A Connections row: the state's symbol, the side's name over its sub line
/// (a small spinner first while it searches or checks), and the action chip.
struct PadStatusRow: View {
    let row: Sidebar.StatusRow
    let perform: (StatusItem.Action) -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .font(.title2)
                    .foregroundStyle(row.tint.color)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.body)
                    HStack(spacing: 4) {
                        if row.spins {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 10, height: 10)
                        }
                        Text(row.subline)
                            .font(.footnote)
                            .foregroundStyle(row.isSublineRed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                    if let server = row.server {
                        Text(server)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(row.detail ?? "")
            .help(row.detail ?? row.subline)
            if let action = row.action {
                Button {
                    perform(action)
                } label: {
                    Text(action.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(.tint, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        // A status row is not a pane.
        .selectionDisabled()
    }
}
#endif
