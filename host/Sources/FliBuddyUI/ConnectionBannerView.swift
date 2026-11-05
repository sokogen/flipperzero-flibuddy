import FliBuddyCore
import SwiftUI

#if os(iOS)
/// The iPhone's glass capsule over the feed: the healthy line, or one line
/// per side in trouble with its action chip. Only the chip reacts to taps;
/// the detail a short phrase leaves out is its accessibility hint, and the
/// chip reads with its side ("Retry Bambuddy"). A phrase that does not fit
/// beside its chip wraps, the chip under it.
struct ConnectionBannerView: View {
    let banner: ConnectionBanner
    let openSettings: (() -> Void)?
    let perform: (StatusItem.Action) -> Void

    /// Half the one-line height: a capsule for one line, the same corners
    /// for two.
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(banner.entries, id: \.item.text) { line($0) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        // Wraps up to the second accessibility size, so the capsule leaves
        // the feed room; VoiceOver and Large Content read the full phrase.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityShowsLargeContentViewer()
        .glassEffect(.regular, in: Self.shape)
        .overlay { Self.shape.strokeBorder(.separator, lineWidth: 0.5) }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func line(_ entry: ConnectionBanner.Entry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                phrase(entry.item)
                chip(entry)
            }
            VStack(alignment: .leading, spacing: 4) {
                phrase(entry.item)
                chip(entry)
            }
        }
        .frame(minHeight: 28)
    }

    private func phrase(_ item: StatusItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            symbol(item)
            Text(item.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.detail ?? "")
    }

    @ViewBuilder private func symbol(_ item: StatusItem) -> some View {
        switch item.symbol {
        case .progress:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        case .symbol(let name):
            Image(systemName: name)
                .font(.callout)
                .foregroundStyle(item.tint.color)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func chip(_ entry: ConnectionBanner.Entry) -> some View {
        if let action = entry.item.action {
            Button {
                if action == .settings {
                    openSettings?()
                } else {
                    perform(action)
                }
            } label: {
                Text(action.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(minHeight: 28)
                    .background(.tint, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.actionLabel ?? action.title)
        }
    }
}
#endif
