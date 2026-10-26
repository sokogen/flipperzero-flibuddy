import SpoolBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// New and Link to existing, for a tag no spool carries.
struct UnknownRowActions: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var showingNew = false
    @ViewState private var showingLink = false

    var body: some View {
        HStack(spacing: 6) {
            Button("New…") { showingNew = true }
                .help(item.hasPrefill ? "Create a Bambuddy item from the tag" : "Create a Bambuddy item; enter the material")
            Button("Link to existing…") { showingLink = true }
                .help("Attach this tag to a spool already in Bambuddy")
            ProgressView().controlSize(.small).opacity(feed.isBusy(item.id) ? 1 : 0)
        }
        .sheet(isPresented: $showingNew) {
            if let form = feed.newSpoolForm(for: item.id) {
                NewSpoolSheet(feed: feed, item: item, form: form)
            }
        }
        .sheet(isPresented: $showingLink) {
            LinkSpoolSheet(feed: feed, item: item)
        }
    }
}

/// The New form, filled in from the tag.
struct NewSpoolSheet: View {
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
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("New Bambuddy item") {
                    TextField("Material", text: $form.material, prompt: Text("required, e.g. PLA"))
                    TextField("Subtype", text: $form.subtype, prompt: Text("e.g. Basic"))
                    TextField("Colour", text: $form.colorName)
                    TextField("Brand", text: $form.brand)
                    TextField("Label weight (g)", text: $form.labelWeight)
                    LabeledContent("Core weight", value: "\(feed.settings.coreWeight) g")
                    LabeledContent("Tag UID", value: item.uid)
                }
                if let error = feed.error(for: item.id) {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        if await feed.create(item.id, form) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.newSpool == nil || feed.isBusy(item.id))
            }
            .padding()
        }
        #if os(macOS)
        // A sheet on macOS sizes to its content; on iOS it fills the screen.
        .frame(minWidth: 420)
        #endif
    }
}

/// Picks the spool to link the tag to, filtered as you type.
struct LinkSpoolSheet: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var query = ""
    @ViewState private var selection: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link tag \(item.uid) to a spool").font(.headline)
            TextField("Filter", text: $query, prompt: Text("material, colour, brand or note"))
                .textFieldStyle(.roundedBorder)
            if let error = feed.linkError {
                Text(error).foregroundStyle(.red)
            }
            List(feed.linkMatches(query), selection: $selection) { spool in
                SpoolPickerRow(spool: spool)
            }
            .overlay {
                if feed.isLoadingLinkCandidates { ProgressView() }
            }
            if let error = feed.error(for: item.id) {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link") {
                    guard let selection else { return }
                    Task {
                        if await feed.link(item.id, toSpool: selection) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || feed.isBusy(item.id))
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .task { await feed.loadLinkCandidates() }
    }
}

struct SpoolPickerRow: View {
    let spool: Spool

    var body: some View {
        HStack(spacing: 10) {
            SwatchView(swatch: spool.rgba.flatMap(Swatch.init(rgba:)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FeedItem.title(material: spool.material, subtype: spool.subtype))
                    if let colorName = spool.colorName {
                        Text(colorName).foregroundStyle(.secondary)
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if spool.tagUid != nil {
                Image(systemName: "tag").foregroundStyle(.secondary).help("Already has a tag")
            }
            Text("#\(spool.id)").foregroundStyle(.tertiary)
        }
    }

    private var details: String {
        [spool.brand, "\(spool.remaining) g left of \(spool.labelWeight)", spool.note]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
#endif
