import FliBuddyCore
import SwiftUI

#if os(watchOS)
/// One row on the watch: a header line, then the body `WatchRowScreen`
/// picks (the crown entry, the saved result, an unknown tag, a spinner),
/// then the tag's Details. `onSaved` follows a save or a New Bambuddy took.
struct WatchRowDetail: View {
    let feed: FeedViewModel
    let id: FeedRow.ID
    let onSaved: (FeedRow.ID) -> Void
    /// New on the watch is on its way to Bambuddy.
    @ViewState private var isCreating = false

    var body: some View {
        if let item = feed.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        SwatchView(swatch: item.swatch, size: 12)
                        Text(item.watchTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    switch WatchRowScreen(item, isCreating: isCreating) {
                    case .entry:
                        WatchWeightEntry(feed: feed, item: item, onSaved: onSaved)
                    case .saved:
                        WatchSavedBody(feed: feed, item: item)
                    case .unknown(let hint, let offersNew):
                        WatchUnknownBody(feed: feed, item: item, hint: hint, offersNew: offersNew, onNew: create)
                    case .busy(let phrase):
                        WatchBusyBody(phrase: phrase)
                    }
                    if let details = feed.tagDetails(for: id), !details.watchFacts.isEmpty {
                        WatchDetailsSection(facts: details.watchFacts)
                    }
                }
            }
        } else {
            ContentUnavailableView("Row cleared", systemImage: "trash")
        }
    }

    /// New in one tap: the spool from the tag's own data, at its label weight.
    private func create() {
        isCreating = true
        Task {
            let created = await feed.addNew(id)
            isCreating = false
            if created { onSaved(id) }
        }
    }
}

/// The weight on the Digital Crown (1 g per detent, 5 g on fast turns), its
/// line, the Net / Gross pills (which convert it) and Save.
struct WatchWeightEntry: View {
    let feed: FeedViewModel
    let item: FeedItem
    let onSaved: (FeedRow.ID) -> Void
    @ViewState private var velocity = 0.0
    @FocusState private var isFocused: Bool

    var body: some View {
        let id = item.id
        let grams = FeedViewModel.grams(from: feed.weightText(for: id))
        let mode = feed.mode(for: id)
        let line = WatchRowScreen.entryLine(item, value: grams, mode: mode, hostError: feed.error(for: id))
        let canSave = feed.canSave(id)
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(grams.map(String.init) ?? "0")
                    .font(.system(size: 50, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(grams == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text("g")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 54)
            .focusable()
            .focused($isFocused)
            .digitalCrownRotation(
                detent: crown,
                from: Double(CrownWeight.range.lowerBound), through: Double(CrownWeight.range.upperBound), by: 1,
                sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true,
                onChange: { velocity = $0.velocity }
            )
            .accessibilityLabel(FeedItem.weightFieldLabel(mode: mode))
            .accessibilityValue(grams.map { "\($0) grams" } ?? WatchRowScreen.turnTheCrownText)
            Text(line.text)
                .font(.system(size: 13))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(line.isError ? AnyShapeStyle(StatusTint.red.watchColor) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
            HStack(spacing: 4) {
                WatchModePill(title: "Net", isSelected: mode == .net) { feed.setMode(.net, for: id) }
                WatchModePill(title: "Gross", isSelected: mode == .gross) { feed.setMode(.gross, for: id) }
            }
            .disabled(item.isSaving)
            Button(feed.saveTitle(for: id)) {
                Task {
                    if await feed.save(id) { onSaved(id) }
                }
            }
            .buttonStyle(WatchCapsuleButtonStyle(fill: StatusTint.blue.watchColor))
            .opacity(canSave ? 1 : 0.45)
            .disabled(!canSave)
        }
        .onAppear { isFocused = true }
    }

    /// The crown reads the feed's value (a converted one too) and writes
    /// back what `CrownWeight` makes of the turn; it starts at 0 when empty.
    private var crown: Binding<Double> {
        let id = item.id
        return Binding(
            get: { Double(FeedViewModel.grams(from: feed.weightText(for: id)) ?? 0) },
            set: {
                var weight = CrownWeight(grams: FeedViewModel.grams(from: feed.weightText(for: id)) ?? 0)
                weight.turn(to: $0, velocity: velocity)
                feed.setWeightText(weight.text, for: id)
            }
        )
    }
}

/// Net or Gross: 30 high, 13 sb; the selected one white with black text.
struct WatchModePill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Capsule().fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.16))))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A full-width capsule, 40 high, 16 sb white text.
struct WatchCapsuleButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = .white
    var height: CGFloat = 40
    var fontSize: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Saved, Timeout, Added to Bambuddy, Marked as new / empty: the state
/// symbol, what is left, the phrase and Weigh again.
struct WatchSavedBody: View {
    let feed: FeedViewModel
    let item: FeedItem

    var body: some View {
        VStack(spacing: 4) {
            WatchStatusSymbol(item: item, size: 34)
            if let remaining = WatchRowScreen.remainingText(item) {
                Text(remaining)
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Text(item.statusText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Weigh again") { Task { await feed.reopen(item.id) } }
                .buttonStyle(WatchCapsuleButtonStyle(fill: .white.opacity(0.16)))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

/// No spool: the sub line, the phrase, a hint where the phone or the Mac has
/// to act, and the one New button for a tag with material.
struct WatchUnknownBody: View {
    let feed: FeedViewModel
    let item: FeedItem
    let hint: String?
    let offersNew: Bool
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.watchSubText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WatchStatusSymbol(item: item, size: 17)
                Text(item.statusText).font(.system(size: 15))
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let error = feed.error(for: item.id) {
                Text("Error: \(error)")
                    .font(.system(size: 13))
                    .foregroundStyle(StatusTint.red.watchColor)
            }
            if offersNew {
                Button(FeedItem.RowAction.new.title, action: onNew)
                    .buttonStyle(WatchCapsuleButtonStyle(fill: StatusTint.blue.watchColor))
                    .disabled(feed.isBusy(item.id))
                    .padding(.top, 4)
            }
        }
    }
}

/// Looking up, Creating: a 26 pt spinner and the phrase.
struct WatchBusyBody: View {
    let phrase: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().frame(width: 26, height: 26)
            Text(phrase)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// The row's status symbol at `size` in the watch's tint.
struct WatchStatusSymbol: View {
    let item: FeedItem
    let size: CGFloat

    var body: some View {
        if case .symbol(let name) = item.statusSymbol {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(item.statusTint.watchColor)
                .accessibilityHidden(true)
        }
    }
}

/// The tag's facts under the body, reached by scrolling.
struct WatchDetailsSection: View {
    let facts: [TagDetails.Fact]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Details")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(facts) { fact in
                LabeledContent(fact.label) {
                    Text(fact.value)
                        .font(fact.isIdentifier ? .system(size: 13).monospaced() : .system(size: 13))
                        .lineLimit(2)
                }
                .font(.system(size: 13))
            }
        }
        .padding(.top, 8)
    }
}
#endif
