import FliBuddyCore
import SwiftUI

#if os(watchOS)
/// One row on the watch: the weight on the Digital Crown with the net/gross
/// toggle and Save for a known spool, New for an unknown tag.
struct WatchRowDetail: View {
    let feed: FeedViewModel
    let id: FeedRow.ID

    var body: some View {
        if let item = feed.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SwatchView(swatch: item.swatch)
                        VStack(alignment: .leading, spacing: 1) {
                            if let colorName = item.colorName {
                                Text(colorName).font(.footnote)
                            }
                            if !item.remainingText.isEmpty {
                                Text(item.remainingText).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(item.statusText)
                        .font(.footnote)
                        .foregroundStyle(item.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    if item.canWeigh {
                        WatchWeightEntry(feed: feed, item: item)
                    } else if item.offersUnknownActions {
                        WatchUnknownActions(feed: feed, item: item)
                    } else {
                        ProgressView()
                    }
                    if let error = feed.error(for: id) {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(item.title)
        } else {
            ContentUnavailableView("Row cleared", systemImage: "trash")
        }
    }
}

/// The weight bound to the Digital Crown: 1 g per step, 5 g on fast turns.
struct WatchWeightEntry: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var weight = CrownWeight(grams: 0)
    @ViewState private var velocity = 0.0
    @ViewState private var seeded = false

    var body: some View {
        let id = item.id
        VStack(spacing: 6) {
            Text("\(weight.grams) g")
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .frame(maxWidth: .infinity)
                .focusable()
                .digitalCrownRotation(
                    detent: crown,
                    from: Double(CrownWeight.range.lowerBound), through: Double(CrownWeight.range.upperBound), by: 1,
                    sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true,
                    onChange: { velocity = $0.velocity }
                )
            Toggle(
                "Gross",
                isOn: Binding(get: { feed.mode(for: id) == .gross }, set: { feed.setMode($0 ? .gross : .net, for: id) })
            )
            Button("Save") {
                Task { await feed.save(id) }
            }
            .disabled(!feed.canSave(id))
            if feed.isBusy(id) {
                ProgressView()
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            weight = .seed(typed: feed.weightText(for: id), suggested: item.suggested(feed.mode(for: id)))
            feed.setWeightText(weight.text, for: id)
        }
    }

    private var crown: Binding<Double> {
        Binding(
            get: { Double(weight.grams) },
            set: {
                weight.turn(to: $0, velocity: velocity)
                feed.setWeightText(weight.text, for: item.id)
            }
        )
    }
}

/// New for a tag no spool carries; linking stays on the phone and the Mac.
struct WatchUnknownActions: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var showingNew = false

    var body: some View {
        Button("New") { showingNew = true }
            .disabled(feed.isBusy(item.id))
            .sheet(isPresented: $showingNew) {
                if let form = feed.newSpoolForm(for: item.id) {
                    WatchNewSpool(feed: feed, item: item, form: form)
                }
            }
    }
}

/// The New form, filled in from the tag; Create needs a material.
struct WatchNewSpool: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var form: NewSpoolForm
    @Environment(\.dismiss) private var dismiss

    init(feed: FeedViewModel, item: FeedItem, form: NewSpoolForm) {
        self.feed = feed
        self.item = item
        _form = ViewState(initialValue: form)
    }

    var body: some View {
        Form {
            TextField("Material", text: $form.material, prompt: Text("Material (required)"))
            TextField("Subtype", text: $form.subtype)
            TextField("Colour", text: $form.colorName)
            TextField("Brand", text: $form.brand)
            TextField("Label weight (g)", text: $form.labelWeight)
            LabeledContent("Core", value: "\(feed.settings.coreWeight) g")
            if let error = feed.error(for: item.id) {
                Text(error).foregroundStyle(.red)
            }
            Button("Create") {
                Task {
                    if await feed.create(item.id, form) { dismiss() }
                }
            }
            .disabled(form.newSpool == nil || feed.isBusy(item.id))
        }
        .navigationTitle("New item")
    }
}
#endif
