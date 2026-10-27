import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// A row's actions (`FeedItem.rowActions`): Save as new, Save with weight…
/// and Link to existing… on a New spool; Set weight… and Link on a Created
/// row; New… (the form) or Save as new and Link on another tag no spool
/// carries; Cancel beside a revealed entry.
struct RowActions: View {
    enum Style {
        /// Bordered buttons, the prominent one `.borderedProminent` (macOS).
        case buttons
        /// Link-style buttons beside the readout of a revealed entry, or
        /// under the iPad table's status, where the Flipper's request is
        /// semibold rather than prominent.
        case compact
        /// The lead action full width and 50 pt high over the others as
        /// equal 44 pt capsules 10 apart; without a lead, the first capsule
        /// is the prominent one (iPhone card).
        case card
        /// Capsules sized to their titles, 44 high and 8 apart, the
        /// prominent one tinted (iPad table's trailing column).
        case pills
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
            // Three buttons fit the entry's column at the regular size.
            ViewThatFits(in: .horizontal) {
                buttons
                buttons.controlSize(.regular)
                buttons.controlSize(.small)
            }
        case .compact:
            HStack(spacing: 12) {
                cancelButton
                ForEach(compactActions, id: \.self) { action in
                    button(action).fontWeight(action == item.prominentRowAction ? .semibold : .regular)
                }
            }
            #if os(macOS)
            .buttonStyle(.link).font(.footnote).controlSize(.small)
            #else
            // Borderless: in a list row each button keeps its own tap.
            .buttonStyle(.borderless).font(.footnote)
            #endif
        case .card:
            // The row's status shows the spinner while an action runs.
            VStack(spacing: 10) {
                if let lead = item.cardLeadAction {
                    capsule(lead, prominent: true, height: 36)
                }
                HStack(spacing: 10) {
                    if item.offersCancel {
                        capsule(nil, prominent: false, height: 30)
                    }
                    ForEach(item.cardCapsuleActions, id: \.self) { action in
                        capsule(action, prominent: action == item.cardProminentCapsule, height: 30)
                    }
                }
            }
        case .pills:
            #if os(iOS)
            HStack(spacing: 8) {
                ForEach(item.tableTrailingActions, id: \.self) { action in
                    pill(action, prominent: action == item.tableProminentAction)
                }
            }
            #else
            buttons
            #endif
        }
    }

    /// Beside a revealed entry: its Link; under the iPad table's status:
    /// the Link a New spool or Created row has no room for elsewhere.
    private var compactActions: [FeedItem.RowAction] {
        #if os(iOS)
        item.tableStatusActions
        #else
        item.rowActions
        #endif
    }

    private func perform(_ action: FeedItem.RowAction) {
        switch action {
        case .saveAsNew: Task { await feed.saveAsNew(item.id) }
        case .saveWithWeight, .setWeight: feed.revealEntry(item.id)
        case .newForm: showingNew = true
        case .link: showingLink = true
        }
    }

    private func help(_ action: FeedItem.RowAction) -> String {
        switch action {
        case .saveAsNew: "Create the spool in Bambuddy from the tag, full"
        case .saveWithWeight: "Enter a weight; Save creates the spool from the tag and records it"
        case .setWeight: "Enter the weight of the spool created on scan"
        case .newForm: "Create a Bambuddy item; enter the material"
        case .link:
            item.offersLinkExisting
                ? "Move this tag to a spool already in Bambuddy and delete the one created on scan"
                : "Attach this tag to a spool already in Bambuddy"
        }
    }

    private func button(_ action: FeedItem.RowAction) -> some View {
        Button(action.title) { perform(action) }
            .help(help(action))
    }

    @ViewBuilder private var cancelButton: some View {
        if item.offersCancel {
            Button("Cancel") { feed.hideEntry(item.id) }
                .help("Hide the weight entry without saving (Esc)")
                .disabled(feed.isSaving(item.id))
        }
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

    /// `action` nil: Cancel.
    @ViewBuilder private func capsule(_ action: FeedItem.RowAction?, prominent: Bool, height: CGFloat) -> some View {
        let button = Button {
            if let action { perform(action) } else { feed.hideEntry(item.id) }
        } label: {
            Text(action?.title ?? "Cancel")
                .font(height > 30 ? .headline : .subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(action == nil && feed.isSaving(item.id))
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    #if os(iOS)
    private func pill(_ action: FeedItem.RowAction, prominent: Bool) -> some View {
        Button {
            perform(action)
        } label: {
            Text(action.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(
                    prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
                    in: .capsule
                )
        }
        .buttonStyle(.borderless)
    }
    #endif
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
