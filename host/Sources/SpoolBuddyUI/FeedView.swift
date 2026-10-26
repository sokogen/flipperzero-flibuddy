import SpoolBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// The session feed: one row per scanned tag, newest first, and the status bar.
public struct FeedView: View {
    let feed: FeedViewModel
    let link: FlipperLink

    public init(feed: FeedViewModel, link: FlipperLink) {
        self.feed = feed
        self.link = link
    }

    public var body: some View {
        VStack(spacing: 0) {
            if feed.items.isEmpty {
                ContentUnavailableView(
                    "No scans yet", systemImage: "wave.3.right",
                    description: Text("Hold a spool's tag to the Flipper running SpoolBuddy.")
                )
            } else {
                List(feed.items) { item in
                    FeedRowView(feed: feed, item: item)
                }
            }
            Divider()
            StatusBar(link: link, bambuddy: feed.bambuddy, colorNamesProblem: feed.colorNamesProblem)
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
}

struct FeedRowView: View {
    let feed: FeedViewModel
    let item: FeedItem

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
                    if let savedBy = item.savedByText {
                        Text(savedBy).foregroundStyle(.tertiary)
                    }
                    Text(item.scannedAt, style: .time).foregroundStyle(.tertiary)
                }
                .font(.caption)
                if let request = item.requestText {
                    Label(request, systemImage: "exclamationmark.bubble")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = feed.error(for: item.id) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            if item.canWeigh {
                WeightEntry(feed: feed, item: item)
            } else if item.offersUnknownActions {
                UnknownRowActions(feed: feed, item: item)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Weight field, net/gross toggle and Save for a known spool.
struct WeightEntry: View {
    let feed: FeedViewModel
    let item: FeedItem

    var body: some View {
        let id = item.id
        let mode = feed.mode(for: id)
        HStack(spacing: 6) {
            TextField(
                "Weight",
                text: Binding(get: { feed.weightText(for: id) }, set: { feed.setWeightText($0, for: id) }),
                prompt: Text(item.suggested(mode).map(String.init) ?? "grams")
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
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
