import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// The session feed: one row per scanned tag, newest first, and the status bar.
public struct FeedView: View {
    let feed: FeedViewModel
    let link: FlipperLink
    /// The weight field with the keyboard, kept in step with `feed.focusedRow`.
    @FocusState private var focusedField: FeedRow.ID?

    public init(feed: FeedViewModel, link: FlipperLink) {
        self.feed = feed
        self.link = link
    }

    public var body: some View {
        VStack(spacing: 0) {
            if feed.items.isEmpty {
                ContentUnavailableView(
                    "No scans yet", systemImage: "wave.3.right",
                    description: Text("Hold a spool's tag to the Flipper running FliBuddy.")
                )
            } else {
                feedList
            }
            Divider()
            StatusBar(link: link, bambuddy: feed.bambuddy, colorNamesProblem: feed.colorNamesProblem)
        }
        .background { FeedKeyboardShortcuts(feed: feed) }
        .onAppear { focusField(on: feed.focusedRow) }
        .onChange(of: feed.focusedRow) { _, row in focusField(on: row) }
        .onChange(of: focusedField) { _, row in
            // Losing the field keeps the row focused, so ⌘S still has a target.
            if let row { feed.focusedRow = row }
        }
        .toolbar {
            ToolbarItem {
                Button("Clear", systemImage: "trash") {
                    Task { await feed.clear() }
                }
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

    /// The field of a row in weight entry takes the keyboard; AppKit selects
    /// its text, so the first keystroke replaces the suggestion.
    private func focusField(on row: FeedRow.ID?) {
        focusedField = row.flatMap { feed.item($0)?.isEntry == true ? $0 : nil }
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

struct FeedRowView: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SwatchView(swatch: item.swatch)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.headline)
                    if let colorName = item.colorName {
                        Text(colorName).foregroundStyle(.secondary)
                    }
                }
                if !item.remainingText.isEmpty {
                    Text(item.remainingText).font(.callout)
                }
                HStack(spacing: 6) {
                    Text(item.statusText).foregroundStyle(item.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Text(item.scannedAt, style: .time).foregroundStyle(.tertiary)
                }
                .font(.caption)
                if let note = item.timeoutNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let error = feed.error(for: item.id) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            if item.isEntry {
                if item.isCreated {
                    LinkExistingButton(feed: feed, item: item)
                }
                WeightEntry(feed: feed, item: item, focusedField: focusedField)
            } else if item.isReopenable {
                Button("Re-weigh") { Task { await feed.reopen(item.id) } }
            } else if item.offersUnknownActions {
                UnknownRowActions(feed: feed, item: item)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .overlay {
            // A row that waits while the user types in another one.
            if feed.focus.hintedRow == item.id {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2)
            }
        }
    }
}

/// Weight field, net/gross toggle and Save for a known spool. Tab goes
/// field → mode → Save in view order.
struct WeightEntry: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding

    var body: some View {
        let id = item.id
        let mode = feed.mode(for: id)
        HStack(spacing: 6) {
            TextField(
                "Weight",
                text: Binding(get: { feed.weightText(for: id) }, set: { feed.setWeightText($0, for: id) }),
                prompt: Text(item.suggestion(mode: mode).map(String.init) ?? "grams")
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .focused(focusedField, equals: id)
            .onSubmit { Task { await feed.save(id) } }
            Text("g").foregroundStyle(.secondary)
            Picker("Mode", selection: Binding(get: { feed.mode(for: id) }, set: { feed.setMode($0, for: id) })) {
                Text("Net").tag(Intent.WeightMode.net)
                Text("Gross").tag(Intent.WeightMode.gross)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help("Net: filament only. Gross: spool on the scale, core included.")
            .onKeyPress(.leftArrow) {
                feed.setMode(.net, for: id)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                feed.setMode(.gross, for: id)
                return .handled
            }
            Button("Save") {
                Task { await feed.save(id) }
            }
            .disabled(!feed.canSave(id))
            ProgressView().controlSize(.small).opacity(feed.isBusy(id) ? 1 : 0)
        }
    }
}

/// Transport state, Bambuddy state and a colour map that failed to load.
struct StatusBar: View {
    let link: FlipperLink
    let bambuddy: BambuddyState
    let colorNamesProblem: String?

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(linkColor).frame(width: 8, height: 8)
                Text(link.statusText)
            }
            HStack(spacing: 6) {
                Circle().fill(bambuddy.isReady ? .green : .orange).frame(width: 8, height: 8)
                Text(bambuddy.statusText)
            }
            if let colorNamesProblem {
                Text(colorNamesProblem).foregroundStyle(.orange).help(colorNamesProblem)
            }
            Spacer()
            if let port = link.port {
                Text(port).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var linkColor: Color {
        switch link.state {
        case .connected: .green
        case .waitingForHello: .yellow
        case .noAnswer, .disconnected: .orange
        }
    }
}
#endif
