import FliBuddyCore
import SwiftUI

#if os(watchOS)
/// The watch app: one navigation stack, the feed at its root, a row's detail
/// or Settings (behind the connection glyph) on top. A row that starts
/// waiting for a weight opens on its own while the feed shows; a detail pops
/// back a second after its save (`WatchNavigation`).
public struct WatchRootView: View {
    let host: HostModel
    let receiver: WatchSettingsReceiver?
    @ViewState private var navigation = WatchNavigation()

    public init(host: HostModel, receiver: WatchSettingsReceiver?) {
        self.host = host
        self.receiver = receiver
    }

    public var body: some View {
        let feed = host.feed
        NavigationStack(path: $navigation.path) {
            WatchFeedView(feed: feed, glyph: host.watchGlyph) { navigation.open($0) } onSettings: {
                navigation.openSettings()
            }
            .navigationDestination(for: WatchNavigation.Screen.self) { screen in
                switch screen {
                case .row(let id):
                    WatchRowDetail(feed: feed, id: id) { saved in
                        Task {
                            try? await Task.sleep(for: WatchNavigation.popDelay)
                            navigation.popAfterSave(saved)
                        }
                    }
                case .settings:
                    WatchSettingsView(host: host, receiver: receiver)
                }
            }
        }
        .onAppear { navigation.update(feed.items) }
        .onChange(of: feed.items) { _, items in navigation.update(items) }
    }
}

/// The feed: one platter per scan, newest first, and the connection glyph
/// top leading. In Always-On only the titles and sub lines show, dimmed, and
/// rows take no taps.
struct WatchFeedView: View {
    let feed: FeedViewModel
    let glyph: StatusItem
    let onOpen: (FeedRow.ID) -> Void
    let onSettings: () -> Void
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    static let emptyText = "Hold a spool\u{2019}s tag to the Flipper running FliBuddy."

    var body: some View {
        Group {
            if feed.items.isEmpty {
                Text(Self.emptyText)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(feed.items) { item in
                    if isLuminanceReduced {
                        WatchFeedRow(item: item, isBusy: feed.isBusy(item.id), isReduced: true)
                            .listRowBackground(Color.clear)
                    } else {
                        Button { onOpen(item.id) } label: {
                            WatchFeedRow(item: item, isBusy: feed.isBusy(item.id), isReduced: false)
                        }
                        .listRowBackground(WatchPlatter())
                    }
                }
            }
        }
        .navigationTitle("FliBuddy")
        .toolbar {
            if !isLuminanceReduced {
                ToolbarItem(placement: .topBarLeading) {
                    WatchConnectionGlyph(status: glyph, action: onSettings)
                }
            }
        }
    }
}

/// The feed's platter: `#222224`, corner 20.
struct WatchPlatter: View {
    static let fill = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x24 / 255)

    var body: some View {
        RoundedRectangle(cornerRadius: 20).fill(Self.fill)
    }
}

/// Swatch 16 · title over the short sub line · status glyph 19 in a 22 pt
/// column (a spinner while the row is busy).
struct WatchFeedRow: View {
    let item: FeedItem
    let isBusy: Bool
    let isReduced: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !isReduced {
                SwatchView(swatch: item.swatch, size: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.watchTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isReduced ? AnyShapeStyle(.white.opacity(0.55)) : AnyShapeStyle(.primary))
                if !item.watchSubText.isEmpty {
                    Text(item.watchSubText)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(isReduced ? AnyShapeStyle(.white.opacity(0.35)) : AnyShapeStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isReduced {
                statusGlyph
                    .frame(width: 22)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.statusText)
    }

    @ViewBuilder private var statusGlyph: some View {
        Group {
            if isBusy || item.statusSymbol == .progress {
                ProgressView().frame(width: 14, height: 14)
            } else if case .symbol(let name) = item.statusSymbol {
                Image(systemName: name)
                    .font(.system(size: 19))
                    .foregroundStyle(item.statusTint.watchColor)
            }
        }
        .accessibilityLabel(item.statusText)
    }
}

/// The 30 pt glyph button top leading: one symbol in its tint (a spinner
/// while searching); it opens Settings and reads the phrase.
struct WatchConnectionGlyph: View {
    let status: StatusItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(0.16))
                switch status.symbol {
                case .progress:
                    ProgressView().frame(width: 13, height: 13)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 16))
                        .foregroundStyle(status.tint.watchColor)
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.text)
        .accessibilityHint("Opens Settings")
    }
}

extension StatusTint {
    /// The watch page's colours; its secondary glyphs are gray `#8E8E93`.
    var watchColor: Color {
        switch self {
        case .blue: Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
        case .green: Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
        case .orange: Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
        case .red: Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
        case .secondary, .gray: Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
        }
    }
}
#endif
