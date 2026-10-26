import SpoolBuddyCore
import SwiftUI

#if os(watchOS)
/// The feed on the watch: the link and Bambuddy state, then one row per scan,
/// newest first; a row opens its detail.
public struct WatchFeedView: View {
    let feed: FeedViewModel
    let link: FlipperLink

    public init(feed: FeedViewModel, link: FlipperLink) {
        self.feed = feed
        self.link = link
    }

    public var body: some View {
        List {
            Section {
                WatchStatus(link: link, bambuddy: feed.bambuddy)
            }
            if feed.items.isEmpty {
                ContentUnavailableView(
                    "No scans yet", systemImage: "wave.3.right",
                    description: Text("Hold a spool's tag to the Flipper.")
                )
            } else {
                ForEach(feed.items) { item in
                    NavigationLink {
                        WatchRowDetail(feed: feed, id: item.id)
                    } label: {
                        WatchFeedRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("SpoolBuddy")
    }
}

/// Colour, material, what is left and the row status.
struct WatchFeedRow: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 8) {
            SwatchView(swatch: item.swatch)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.headline).lineLimit(1)
                if !item.remainingText.isEmpty {
                    Text(item.remainingText).font(.footnote).lineLimit(1)
                }
                Text(item.statusText)
                    .font(.footnote)
                    .foregroundStyle(item.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
        }
    }
}

/// The Flipper link and Bambuddy state, one line each.
struct WatchStatus: View {
    let link: FlipperLink
    let bambuddy: BambuddyState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(link.statusText)
            } icon: {
                Circle().fill(linkColor).frame(width: 8, height: 8)
            }
            Label {
                Text(bambuddy.statusText)
            } icon: {
                Circle().fill(bambuddy.isReady ? .green : .orange).frame(width: 8, height: 8)
            }
        }
        .font(.footnote)
        .lineLimit(2)
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
