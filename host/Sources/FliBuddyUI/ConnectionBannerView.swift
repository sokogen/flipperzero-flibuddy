import FliBuddyCore
import SwiftUI

#if os(iOS)
/// The iPhone's glass capsule over the feed: the healthy line, or one line
/// per side in trouble with its action chip. Only the chip reacts to taps;
/// the detail a short phrase leaves out is its accessibility hint.
struct ConnectionBannerView: View {
    let banner: ConnectionBanner
    let openSettings: (() -> Void)?
    let perform: (StatusItem.Action) -> Void

    /// Half the one-line height: a capsule for one line, the same corners
    /// for two.
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(banner.lines, id: \.text) { line($0) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .glassEffect(.regular, in: Self.shape)
        .overlay { Self.shape.strokeBorder(.separator, lineWidth: 0.5) }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func line(_ item: StatusItem) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                symbol(item)
                Text(item.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(item.detail ?? "")
            if let action = item.action {
                chip(action)
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private func symbol(_ item: StatusItem) -> some View {
        switch item.symbol {
        case .progress:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 16))
                .foregroundStyle(item.tint.color)
                .accessibilityHidden(true)
        }
    }

    private func chip(_ action: StatusItem.Action) -> some View {
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
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.tint, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
#endif
