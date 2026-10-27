import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// The session feed: one row per scanned tag, newest first, and the status
/// bar. In Spoolman mode an explanation replaces the feed.
public struct FeedView: View {
    let host: HostModel
    /// Opens the settings for the status bar's Settings button; macOS uses
    /// its Settings scene instead.
    let openSettings: (() -> Void)?
    /// The weight field with the keyboard, kept in step with `feed.focusedRow`.
    @FocusState private var focusedField: FeedRow.ID?
    @ViewState private var confirmingClear = false

    private var feed: FeedViewModel { host.feed }

    public init(host: HostModel, openSettings: (() -> Void)? = nil) {
        self.host = host
        self.openSettings = openSettings
    }

    public var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(
                    flipper: host.link.statusItem, bambuddy: feed.bambuddyStatus, openSettings: openSettings
                ) { action in
                    Task { await host.perform(action) }
                }
            }
            .background { FeedKeyboardShortcuts(feed: feed) }
            // The field of a row in weight entry takes the keyboard; AppKit
            // selects its text, so the first keystroke replaces the suggestion.
            .onAppear { focusedField = feed.focusedField }
            .onChange(of: feed.focusedField) { _, row in focusedField = row }
            .onChange(of: focusedField) { _, row in
                // Losing the field keeps the row focused, so ⌘S still has a target.
                if let row { feed.focusedRow = row }
            }
            .confirmationDialog("Clear the feed?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    Task { await feed.clear() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the session log only. Nothing changes in Bambuddy.")
            }
            .toolbar {
                ToolbarItem {
                    Button("Clear", systemImage: "trash") { confirmingClear = true }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .help("Remove all rows from the feed")
                        .disabled(feed.items.isEmpty)
                }
                #if os(macOS)
                ToolbarItem {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                #endif
            }
    }

    @ViewBuilder private var content: some View {
        if feed.isBlocked {
            ContentUnavailableView {
                Label {
                    Text("Bambuddy is in Spoolman mode")
                } icon: {
                    Image(systemName: "nosign").foregroundStyle(.red)
                }
            } description: {
                Text(
                    "FliBuddy works with Bambuddy's own inventory. Switch Bambuddy's inventory back from Spoolman in its settings, then retry."
                )
            } actions: {
                Button("Retry") {
                    Task { await host.checkBambuddy() }
                }
                .disabled(feed.isCheckingBambuddy)
            }
        } else if feed.items.isEmpty {
            ContentUnavailableView(
                "No scans yet", systemImage: "wave.3.right",
                description: Text("Hold a spool's tag to the Flipper running FliBuddy.")
            )
        } else {
            feedList
        }
    }

    @ViewBuilder private var feedList: some View {
        #if os(macOS)
        List(feed.items, selection: Binding(get: { feed.focusedRow }, set: { feed.focusedRow = $0 })) { item in
            FeedRowView(feed: feed, item: item, focusedField: $focusedField)
        }
        #else
        List(feed.items) { item in
            FeedRowView(feed: feed, item: item, focusedField: $focusedField)
        }
        #endif
    }
}

/// ⌘S saves the focused row, ⌘↑ / ⌘↓ move between rows. Invisible buttons,
/// so each shortcut exists once rather than on every row.
struct FeedKeyboardShortcuts: View {
    let feed: FeedViewModel

    var body: some View {
        ZStack {
            Button("Save Focused Row") { Task { await feed.saveFocused() } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Previous Row") { feed.moveFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Row") { feed.moveFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// One feed row. On macOS a single line with fixed columns: swatch · title
/// · colour line · status · weight entry. Rows outside weight entry keep the
/// entry block's space empty so the columns line up. iOS stacks the entry
/// block under the header until its own spec lands. The UID and the other
/// tag facts are in Tag details (context menu, VoiceOver action).
struct FeedRowView: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    @ViewState private var showingDetails = false

    /// Field 96 + unit + segmented 150 + Save, with 8 pt between them.
    static let entryWidth: CGFloat = 360

    var body: some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { reopenIfSaved() }, including: item.isReopenable ? .all : .subviews)
            .accessibilityActions {
                if item.isReopenable {
                    Button("Re-weigh") { reopenIfSaved() }
                }
                Button("Tag details") { showingDetails = true }
            }
            .contextMenu {
                Button("Tag details", systemImage: "info.circle") { showingDetails = true }
            }
            .sheet(isPresented: $showingDetails) {
                if let details = feed.tagDetails(for: item.id) {
                    TagDetailsSheet(details: details)
                }
            }
            .help(Text("Scanned \(item.scannedAt, style: .time)"))
            .overlay {
                // A row that waits while the user types in another one.
                if feed.focus.hintedRow == item.id {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2)
                }
            }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        HStack(alignment: .center, spacing: 12) {
            header
            trailing.frame(width: Self.entryWidth, alignment: .leading)
        }
        .controlSize(.large)
        .frame(minHeight: 60)
        #else
        VStack(alignment: .leading, spacing: 12) {
            header
            trailing
        }
        .padding(.vertical, 4)
        #endif
    }

    /// Swatch, title, colour line, status: one element for VoiceOver.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            SwatchView(swatch: item.swatch, size: 28)
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(item.detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            status.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityHeader)
        // The timeout note and a failed host action sit in the header too.
        .accessibilityValue([item.timeoutNote, feed.error(for: item.id)].compactMap { $0 }.joined(separator: " "))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                StatusSymbolView(symbol: item.statusSymbol, tint: item.statusTint)
                Text(item.statusText)
                    .foregroundStyle(item.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .font(.subheadline)
            if let note = item.timeoutNote {
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = feed.error(for: item.id) {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2).help(error)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if item.isEntry {
            WeightEntry(feed: feed, item: item, focusedField: focusedField)
        } else if item.offersUnknownActions {
            UnknownRowActions(feed: feed, item: item)
        } else {
            // Saved, timed out or looking up: the space stays empty.
            Color.clear.frame(height: 1)
        }
    }

    /// A click on a saved row opens it again for a re-weigh.
    private func reopenIfSaved() {
        guard item.isReopenable else { return }
        Task { await feed.reopen(item.id) }
    }
}

/// A spinner while something runs, else the state's SF Symbol in its tint.
struct StatusSymbolView: View {
    let symbol: StatusSymbol
    let tint: StatusTint

    var body: some View {
        switch symbol {
        case .progress:
            ProgressView().controlSize(.small)
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(tint.color)
        }
    }
}

extension StatusTint {
    var color: Color {
        switch self {
        case .secondary: .secondary
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .gray: .gray
        }
    }
}

/// Weight field with its "g" unit, Net/Gross and Save, the readout under the
/// field, and Link to existing… on a row created on scan, or New and Link to
/// existing… on a tag no spool carries (Save then creates the spool and
/// records the weight). Tab goes field → mode → Save in view order.
struct WeightEntry: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    /// The weight is the one custom-sized type: 22 pt at the default size.
    @ScaledMetric(relativeTo: .largeTitle) private var weightSize: CGFloat = 22

    var body: some View {
        let id = item.id
        let mode = feed.mode(for: id)
        let saving = feed.isSaving(id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    field(id: id, mode: mode)
                    Text("g")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Picker("Mode", selection: Binding(get: { feed.mode(for: id) }, set: { feed.setMode($0, for: id) })) {
                    Text("Net").tag(Intent.WeightMode.net)
                    Text("Gross").tag(Intent.WeightMode.gross)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("Net: filament only. Gross: spool on the scale, core included.")
                .onKeyPress(.leftArrow) {
                    feed.setMode(.net, for: id)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    feed.setMode(.gross, for: id)
                    return .handled
                }
                Button {
                    Task { await feed.save(id) }
                } label: {
                    Text(feed.saveTitle(for: id)).font(.headline).frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!feed.canSave(id))
                .help(item.savesNewSpool ? "Create the spool in Bambuddy from the tag and save the weight" : "Save the weight")
            }
            .disabled(saving)
            HStack(spacing: 8) {
                if let readout = feed.readout(for: id) {
                    Text(readout.text)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(readout.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.offersLinkExisting {
                    #if os(macOS)
                    LinkExistingButton(feed: feed, item: item)
                        .buttonStyle(.link)
                        .font(.footnote)
                        .controlSize(.small)
                    #else
                    LinkExistingButton(feed: feed, item: item).font(.footnote)
                    #endif
                } else if item.offersUnknownActions {
                    UnknownRowActions(feed: feed, item: item, compact: true)
                }
            }
        }
    }

    private func field(id: FeedRow.ID, mode: Intent.WeightMode) -> some View {
        TextField(
            FeedItem.weightFieldLabel(mode: mode),
            text: Binding(get: { feed.weightText(for: id) }, set: { feed.setWeightText($0, for: id) }),
            prompt: Text(item.suggestion(mode: mode).map(String.init) ?? "")
        )
        .labelsHidden()
        .accessibilityLabel(FeedItem.weightFieldLabel(mode: mode))
        .textFieldStyle(.plain)
        .font(.system(size: weightSize, weight: .bold, design: .rounded).monospacedDigit())
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 8)
        .frame(width: 96, height: 34)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            // The focus ring: a plain field draws none of its own.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    focusedField.wrappedValue == id ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                    lineWidth: focusedField.wrappedValue == id ? 2 : 0.5
                )
        }
        .focused(focusedField, equals: id)
        .onSubmit { Task { await feed.save(id) } }
    }
}

/// The Flipper item and the Bambuddy item, each a symbol and a phrase with
/// its reason in the tooltip, and the button the state offers.
struct StatusBar: View {
    let flipper: StatusItem
    let bambuddy: StatusItem
    let openSettings: (() -> Void)?
    let perform: (StatusItem.Action) -> Void

    var body: some View {
        HStack(spacing: 16) {
            item(flipper)
            item(bambuddy)
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func item(_ item: StatusItem) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                StatusSymbolView(symbol: item.symbol, tint: item.tint)
                Text(item.text)
            }
            .help(item.detail ?? item.text)
            .accessibilityElement(children: .combine)
            if let action = item.action {
                button(action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func button(_ action: StatusItem.Action) -> some View {
        if action == .settings {
            #if os(macOS)
            SettingsLink { Text(action.title) }
            #else
            if let openSettings { Button(action.title, action: openSettings) }
            #endif
        } else {
            Button(action.title) { perform(action) }
        }
    }
}
#endif
