import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// New and Link to existing, for a tag no spool carries. New opens the form
/// for a tag without material and creates from the tag otherwise; the
/// action the Flipper asked for is the prominent one.
struct UnknownRowActions: View {
    enum Style {
        /// Bordered buttons, the requested one prominent (macOS).
        case buttons
        /// Link-style buttons under the weight field of a tag with material,
        /// where the Flipper's request is semibold rather than prominent (macOS).
        case compact
        /// Two equal capsules, 44 high and 10 apart, the prominent one first:
        /// New unless the Flipper asked to link (iPhone card).
        case capsules
    }

    let feed: FeedViewModel
    let item: FeedItem
    var style = Style.buttons
    @ViewState private var showingNew = false
    @ViewState private var showingLink = false

    var body: some View {
        content
            .disabled(feed.isBusy(item.id))
            .sheet(isPresented: $showingNew) {
                if let form = feed.newSpoolForm(for: item.id) {
                    NewSpoolSheet(feed: feed, item: item, form: form).feedSheet(feed)
                }
            }
            .sheet(isPresented: $showingLink) {
                LinkSpoolSheet(feed: feed, item: item).feedSheet(feed)
            }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .buttons:
            buttons
        case .compact:
            #if os(macOS)
            buttons.buttonStyle(.link).font(.footnote).controlSize(.small)
            #else
            buttons.font(.footnote)
            #endif
        case .capsules:
            // The row's status shows the spinner while New or Link runs.
            HStack(spacing: 10) {
                ForEach(item.cardActions, id: \.self) { action in
                    capsule(action, prominent: action == item.cardActions.first)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            styled(newButton, prominent: item.prominentAction == .new)
            styled(linkButton, prominent: item.prominentAction == .link)
            ProgressView().controlSize(.small).opacity(feed.isBusy(item.id) ? 1 : 0)
        }
    }

    private var newButton: some View {
        Button(item.newAction.title) { new() }
            .help(item.newAction == .form ? "Create a Bambuddy item; enter the material" : "Create a Bambuddy item from the tag")
    }

    private var linkButton: some View {
        Button("Link to existing\u{2026}") { showingLink = true }
            .help("Attach this tag to a spool already in Bambuddy")
    }

    @ViewBuilder private func capsule(_ action: FeedItem.UnknownAction, prominent: Bool) -> some View {
        let button = Button {
            switch action {
            case .new: new()
            case .link: showingLink = true
            }
        } label: {
            Text(action == .new ? item.newAction.title : "Link to existing\u{2026}")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func new() {
        switch item.newAction {
        case .form: showingNew = true
        case .fromTag: Task { await feed.createFromTag(item.id) }
        }
    }

    @ViewBuilder private func styled(_ button: some View, prominent: Bool) -> some View {
        if style == .compact {
            button.fontWeight(prominent ? .semibold : .regular)
        } else if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }
}

/// Link to existing… on a row created on scan: moves the tag to the chosen
/// spool and deletes the one created.
struct LinkExistingButton: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var showingLink = false

    var body: some View {
        Button("Link to existing…") { showingLink = true }
            .help("Move this tag to a spool already in Bambuddy and delete the one created on scan")
            .sheet(isPresented: $showingLink) {
                LinkSpoolSheet(feed: feed, item: item).feedSheet(feed)
            }
    }
}

extension View {
    /// Content of a sheet over the feed: while it shows, no weight field
    /// takes the keyboard (see `FeedViewModel.sheetOpened()`).
    func feedSheet(_ feed: FeedViewModel) -> some View {
        onAppear { feed.sheetOpened() }
            .onDisappear { feed.sheetClosed() }
    }
}

/// The New spool form for a tag without material; Create needs one.
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
            VStack(alignment: .leading, spacing: 2) {
                Text(NewSpoolForm.title).font(.headline)
                Text(form.subtitle).font(.subheadline.monospaced()).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    Picker("Material", selection: $form.material) {
                        Text("Choose\u{2026}").tag("")
                        ForEach(form.materialOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    TextField("Subtype", text: $form.subtype, prompt: Text("e.g. Basic"))
                    TextField("Colour", text: $form.colorName)
                    TextField("Brand", text: $form.brand)
                    LabeledContent("Label weight") {
                        HStack(spacing: 4) {
                            TextField("Label weight", text: $form.labelWeight)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(NewSpoolForm.footer).foregroundStyle(.secondary)
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
                .disabled(!form.canCreate || feed.isBusy(item.id))
            }
            .padding(20)
        }
        #if os(macOS)
        // A sheet on macOS sizes to its content; on iOS it fills the screen.
        .frame(minWidth: 420)
        #endif
    }
}

/// Picks the spool to link the tag to, filtered as you type; a pick that
/// carries another tag moves that link here.
struct LinkSpoolSheet: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let picker = LinkPickerModel(item: item, spools: feed.linkCandidates, query: query, selection: feed.linkSelection)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LinkPickerModel.title).font(.headline)
                Text(picker.tagLine).font(.subheadline.monospaced()).foregroundStyle(.secondary)
            }
            TextField("Filter", text: $query, prompt: Text(LinkPickerModel.placeholder))
                .textFieldStyle(.roundedBorder)
            if let error = feed.linkError {
                Text(error).foregroundStyle(.red)
            }
            List(picker.matches, selection: Bindable(feed).linkSelection) { spool in
                SpoolPickerRow(spool: spool)
            }
            .overlay {
                if feed.isLoadingLinkCandidates {
                    ProgressView()
                } else if let empty = picker.emptyText, feed.linkError == nil {
                    Text(empty).foregroundStyle(.secondary)
                }
            }
            if let warning = picker.warning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if let error = feed.error(for: item.id) {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(picker.linkTitle) {
                    guard let spool = picker.selectedSpool else { return }
                    Task {
                        if await feed.link(item.id, toSpool: spool.id) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!picker.canLink || feed.isBusy(item.id) || feed.isLoadingLinkCandidates)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .task { await feed.loadLinkCandidates() }
    }
}

/// A spool in the Link picker: swatch, title, "colour · brand · n g left",
/// its note, and the tag it already carries.
struct SpoolPickerRow: View {
    let spool: Spool

    var body: some View {
        HStack(spacing: 12) {
            SwatchView(swatch: spool.rgba.flatMap(Swatch.init(rgba:)))
            VStack(alignment: .leading, spacing: 1) {
                Text(FeedItem.title(material: spool.material, subtype: spool.subtype))
                Text(LinkPickerModel.subtitle(spool)).font(.caption).foregroundStyle(.secondary)
                if let note = spool.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            Spacer()
            if let badge = LinkPickerModel.badge(spool) {
                Text(badge)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
        .help("Spool #\(spool.id)")
    }
}
#endif
