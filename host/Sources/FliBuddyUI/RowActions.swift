import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// A row's actions (`FeedItem.rowActions`) on a tag no spool carries: New
/// (from the tag, at its label weight) or New… (the form), and Link to
/// existing…; the prominent one first, New unless the Flipper asked to link.
/// A spool added here that the Flipper asked to relink offers Link alone.
struct RowActions: View {
    enum Style {
        /// Bordered buttons, the prominent one `.borderedProminent` (macOS).
        case buttons
        /// Two equal 44 pt capsules 10 apart, the prominent one first
        /// (iPhone card).
        case card
        /// The same at 36 pt, 8 apart (iPad tile).
        case tile
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
        case .card, .tile:
            // The row's status shows the spinner while an action runs.
            HStack(spacing: style == .tile ? 8 : 10) {
                ForEach(item.rowActions, id: \.self) { action in
                    capsule(action, prominent: action == item.prominentRowAction)
                }
            }
        }
    }

    private func perform(_ action: FeedItem.RowAction) {
        switch action {
        case .new: Task { await feed.addNew(item.id) }
        case .newForm: showingNew = true
        case .link: showingLink = true
        }
    }

    private func help(_ action: FeedItem.RowAction) -> String {
        switch action {
        case .new: "Add the spool to Bambuddy from the tag, at its label weight"
        case .newForm: "Create a Bambuddy item; enter the material"
        case .link:
            // Only a spool added here is offered Link: the Flipper asked to relink it.
            item.spoolId == nil
                ? "Attach this tag to a spool already in Bambuddy"
                : "Move this tag to a spool already in Bambuddy and delete the one added here"
        }
    }

    private func button(_ action: FeedItem.RowAction) -> some View {
        Button(action.title) { perform(action) }
            .help(help(action))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ForEach(item.rowActions, id: \.self) { action in
                if action == item.prominentRowAction {
                    button(action).buttonStyle(.borderedProminent)
                } else {
                    button(action)
                }
            }
            if feed.isBusy(item.id) {
                ProgressView().controlSize(.small)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func capsule(_ action: FeedItem.RowAction, prominent: Bool) -> some View {
        let button = Button {
            perform(action)
        } label: {
            Text(action.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: style == .tile ? 22 : 30)
        }
        .buttonBorderShape(.capsule)
        .controlSize(style == .tile ? .regular : .large)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
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
    #if os(iOS)
    @Environment(\.self) private var environment
    #endif

    init(feed: FeedViewModel, item: FeedItem, form: NewSpoolForm) {
        self.feed = feed
        self.item = item
        _form = ViewState(initialValue: form)
    }

    var body: some View {
        #if os(iOS)
        phoneBody
        #else
        macBody
        #endif
    }

    private func create() {
        Task {
            if await feed.create(item.id, form) { dismiss() }
        }
    }

    #if os(iOS)
    /// iOS spec, "Sheets": Required and Optional sections, a colour picker,
    /// `xmark` / `checkmark` in the navigation bar.
    private var phoneBody: some View {
        NavigationStack {
            Form {
                Section("Required") {
                    Picker("Material", selection: $form.material) {
                        Text("Choose").tag("")
                        ForEach(form.materialOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    TextField("Subtype", text: $form.subtype, prompt: Text("Basic, Matte, HF…"))
                    ColorPicker("Colour", selection: color, supportsOpacity: false)
                    TextField("Colour name", text: $form.colorName, prompt: Text("Lilac"))
                    TextField("Brand", text: $form.brand, prompt: Text("Elegoo"))
                    LabeledContent("Label weight") {
                        HStack(spacing: 4) {
                            TextField("Label weight", text: $form.labelWeight)
                                .labelsHidden()
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Optional")
                } footer: {
                    Text(NewSpoolForm.phoneFooter)
                }
                if let error = feed.error(for: item.id) {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: NewSpoolForm.title, subtitle: form.subtitle)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark") { create() }
                        .disabled(!form.canCreate || feed.isBusy(item.id))
                }
            }
        }
    }

    /// The colour picker's value: the form's swatch, a neutral grey while
    /// the tag has none (nothing is stored until the user picks).
    private var color: Binding<Color> {
        Binding(
            get: { form.swatch.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .gray },
            set: { color in
                let resolved = color.resolve(in: environment)
                form.swatch = Swatch(
                    red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), alpha: 1
                )
            }
        )
    }
    #else
    private var macBody: some View {
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
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canCreate || feed.isBusy(item.id))
            }
            .padding(20)
        }
        // A sheet on macOS sizes to its content.
        .frame(minWidth: 420)
    }
    #endif
}

#if os(iOS)
/// A sheet's inline title with the tag under it, monospaced.
private struct SheetTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

/// Picks the spool to link the tag to, filtered as you type; a pick that
/// carries another tag moves that link here.
struct LinkSpoolSheet: View {
    let feed: FeedViewModel
    let item: FeedItem
    @ViewState private var query = ""
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @ViewState private var confirmingMove = false
    #endif

    private var picker: LinkPickerModel {
        LinkPickerModel(item: item, spools: feed.linkCandidates, query: query, selection: feed.linkSelection)
    }

    private func link() {
        guard let spool = picker.selectedSpool else { return }
        Task {
            if await feed.link(item.id, toSpool: spool.id) { dismiss() }
        }
    }

    var body: some View {
        #if os(iOS)
        phoneBody
        #else
        macBody
        #endif
    }

    #if os(iOS)
    /// The iPad has the room for the move warning under the list, so ✓ moves
    /// the link without the iPhone's alert.
    private var warnsInline: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// iOS spec, "Sheets": a searchable list, a checkmark on the pick, and an
    /// alert before a link moves away from another tag (inline on the iPad).
    private var phoneBody: some View {
        let picker = picker
        return NavigationStack {
            List {
                if let error = feed.linkError {
                    Text(error).foregroundStyle(.red)
                }
                if let error = feed.error(for: item.id) {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(picker.matches) { spool in
                    Button {
                        feed.linkSelection = spool.id
                    } label: {
                        HStack {
                            SpoolPickerRow(spool: spool)
                            if spool.id == picker.selection {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(spool.id == picker.selection ? .isSelected : [])
                }
                if warnsInline, let warning = picker.padWarning {
                    Section {
                        Label {
                            Text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }
                }
            }
            .overlay {
                if feed.isLoadingLinkCandidates {
                    ProgressView()
                } else if let empty = picker.emptyText, feed.linkError == nil {
                    ContentUnavailableView(empty, systemImage: "magnifyingglass")
                }
            }
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(LinkPickerModel.phonePlaceholder)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: LinkPickerModel.phoneTitle, subtitle: picker.uid)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link", systemImage: "checkmark") {
                        if picker.moveAlert == nil || warnsInline { link() } else { confirmingMove = true }
                    }
                    .disabled(!picker.canLink || feed.isBusy(item.id) || feed.isLoadingLinkCandidates)
                }
            }
            .alert(
                picker.moveAlert?.title ?? "", isPresented: $confirmingMove, presenting: picker.moveAlert
            ) { _ in
                Button(LinkPickerModel.moveButton, systemImage: "arrow.left.arrow.right") { link() }
                Button("Cancel", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
        .task { await feed.loadLinkCandidates() }
    }
    #else
    private var macBody: some View {
        let picker = picker
        return VStack(alignment: .leading, spacing: 12) {
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
                Button(picker.linkTitle) { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!picker.canLink || feed.isBusy(item.id) || feed.isLoadingLinkCandidates)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .task { await feed.loadLinkCandidates() }
    }
    #endif
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
