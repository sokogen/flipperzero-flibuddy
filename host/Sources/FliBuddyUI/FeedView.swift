import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// The session feed: one row per scanned tag, newest first, with the status
/// bar under it on macOS and the connection banner over it on iOS (the
/// iPad's table has both states in its sidebar instead). In Spoolman mode an
/// explanation replaces the feed.
public struct FeedView: View {
    let host: HostModel
    /// Opens the settings for the banner's Settings chip; macOS uses its
    /// Settings scene instead.
    let openSettings: (() -> Void)?
    /// The Clear confirmation, when the app's ⌘⌫ command or the iPad sidebar
    /// asks for it too; else the view keeps its own.
    private let externalConfirmingClear: Binding<Bool>?
    /// The weight field with the keyboard, kept in step with `feed.focusedRow`.
    @FocusState private var focusedField: FeedRow.ID?
    @ViewState private var ownConfirmingClear = false
    #if os(iOS)
    @Environment(\.feedLayout) private var layout
    @ViewState private var listWidth: CGFloat = 0
    #endif

    private var feed: FeedViewModel { host.feed }

    private var confirmingClear: Binding<Bool> {
        externalConfirmingClear ?? $ownConfirmingClear
    }

    public init(host: HostModel, openSettings: (() -> Void)? = nil, confirmingClear: Binding<Bool>? = nil) {
        self.host = host
        self.openSettings = openSettings
        externalConfirmingClear = confirmingClear
    }

    public var body: some View {
        content
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(flipper: host.link.statusItem, bambuddy: feed.bambuddyStatus) { action in
                    Task { await host.perform(action) }
                }
            }
            // On iOS the app declares these as menu commands (`FeedCommands`).
            .background { FeedKeyboardShortcuts(feed: feed) }
            #else
            .safeAreaInset(edge: .top, spacing: 0) {
                if layout == .cards {
                    ConnectionBannerView(banner: host.connectionBanner, openSettings: openSettings) { action in
                        Task { await host.perform(action) }
                    }
                }
            }
            #endif
            // The field of a row in weight entry takes the keyboard; AppKit
            // selects its text, so the first keystroke replaces the suggestion.
            .onAppear { focusedField = feed.focusedField }
            .onChange(of: feed.focusedField) { _, row in focusedField = row }
            .onChange(of: focusedField) { _, row in
                // Losing the field keeps the row focused, so ⌘S still has a target.
                if let row { feed.focusedRow = row }
            }
            #if os(iOS)
            // The number pad needs the room; the tabs come back when it lowers.
            .toolbarVisibility(focusedField == nil ? .automatic : .hidden, for: .tabBar)
            .sensoryFeedback(trigger: feed.haptic) { _, haptic in
                switch haptic?.kind {
                case .success: .success
                case .error: .error
                case nil: nil
                }
            }
            #endif
            .modifier(ClearConfirmation(isPresented: confirmingClear, centred: isTable) {
                Task { await feed.clear() }
            })
            .toolbar {
                #if os(iOS)
                // Icon only, at the leading end of the bar; the iPad's table
                // has Clear feed in its sidebar. ⌘⌫ is a menu command.
                if layout == .cards {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear feed", systemImage: "trash") { confirmingClear.wrappedValue = true }
                            .labelStyle(.iconOnly)
                            .disabled(feed.items.isEmpty)
                    }
                }
                #else
                ToolbarItem {
                    Button("Clear", systemImage: "trash") { confirmingClear.wrappedValue = true }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .help("Remove all rows from the feed")
                        .disabled(feed.items.isEmpty)
                }
                #endif
                #if os(macOS)
                ToolbarItem {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                #endif
            }
    }

    /// The iPad's one-line table is showing.
    private var isTable: Bool {
        #if os(iOS)
        layout == .table
        #else
        false
        #endif
    }

    @ViewBuilder private var content: some View {
        if feed.isBlocked {
            ContentUnavailableView {
                Label {
                    Text("Bambuddy is in Spoolman mode")
                } icon: {
                    Image(systemName: "nosign").foregroundStyle(.red)
                }
            } description: {
                Text(
                    "FliBuddy works with Bambuddy's own inventory. Switch Bambuddy's inventory back from Spoolman in its settings, then retry."
                )
            } actions: {
                Button("Retry") {
                    Task { await host.checkBambuddy() }
                }
                .disabled(feed.isCheckingBambuddy)
            }
        } else if feed.items.isEmpty {
            ContentUnavailableView(
                "No scans yet", systemImage: "wave.3.right",
                description: Text("Hold a spool's tag to the Flipper running FliBuddy.")
            )
        } else {
            feedList
        }
    }

    @ViewBuilder private var feedList: some View {
        #if os(macOS)
        List(feed.items, selection: Binding(get: { feed.focusedRow }, set: { feed.focusedRow = $0 })) { item in
            FeedRowView(feed: feed, item: item, focusedField: $focusedField)
        }
        #else
        if layout == .table { tableList } else { cardList }
        #endif
    }

    #if os(iOS)
    /// The side margin that centres 760-wide cards; the list's own on an iPhone.
    private var cardMargin: CGFloat? {
        listWidth > Self.maxCardWidth + 64 ? (listWidth - Self.maxCardWidth) / 2 : nil
    }

    private static let maxCardWidth: CGFloat = 760

    /// The iPad's one-line rows in one inset-grouped card; the focused row
    /// scrolls into view above the number keyboard.
    private var tableList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(feed.items) { item in
                        FeedRowView(feed: feed, item: item, focusedField: $focusedField)
                            .id(item.id)
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: focusedField) { _, row in
                guard let row else { return }
                withAnimation { proxy.scrollTo(row) }
            }
        }
    }

    /// One card per row; the focused row scrolls to the top so its entry
    /// block, Save included, stays clear of the number pad.
    private var cardList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(feed.items) { item in
                    Section {
                        FeedRowView(feed: feed, item: item, focusedField: $focusedField)
                            .id(item.id)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            // A portrait iPad keeps the cards at most 760 wide, centred.
            .contentMargins(.horizontal, cardMargin, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: focusedField) { _, row in
                guard let row else { return }
                withAnimation { proxy.scrollTo(row, anchor: .top) }
            }
        }
    }
    #endif
}

/// "Clear the feed?": an action sheet on the iPhone and the Mac, a centred
/// alert beside the iPad sidebar. Same copy everywhere.
private struct ClearConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let centred: Bool
    let clear: () -> Void

    private static let title = "Clear the feed?"
    private static let message = "This clears the session log only. Nothing changes in Bambuddy."
    /// The destructive button.
    #if os(iOS)
    private static let clearButton = "Clear feed"
    #else
    private static let clearButton = "Clear"
    #endif

    func body(content: Content) -> some View {
        if centred {
            content.alert(Self.title, isPresented: $isPresented) {
                buttons
            } message: {
                Text(Self.message)
            }
        } else {
            content.confirmationDialog(Self.title, isPresented: $isPresented, titleVisibility: .visible) {
                buttons
            } message: {
                Text(Self.message)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(Self.clearButton, role: .destructive, action: clear)
        Button("Cancel", role: .cancel) {}
    }
}

#if os(macOS)
/// ⌘S saves the focused row, ⌘↑ / ⌘↓ move between rows. Invisible buttons,
/// so each shortcut exists once rather than on every row.
struct FeedKeyboardShortcuts: View {
    let feed: FeedViewModel

    var body: some View {
        ZStack {
            Button("Save Focused Row") { Task { await feed.saveFocused() } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Previous Row") { feed.moveFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Row") { feed.moveFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
#endif

/// One feed row. On macOS a single line with fixed columns: swatch · title
/// · colour line · status · weight entry. Rows outside weight entry keep the
/// entry block's space empty so the columns line up. On iOS a stacked card:
/// swatch beside title, colour line and status, the entry block under them;
/// beside the iPad sidebar a single line with the ipados spec's columns.
/// The UID and the other tag facts are in Tag details (context menu,
/// VoiceOver action).
struct FeedRowView: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    @ViewState private var showingDetails = false
    #if os(iOS)
    @Environment(\.feedLayout) private var layout
    #endif

    /// Field 96 + unit + segmented 150 + Save, with 8 pt between them.
    static let entryWidth: CGFloat = 360

    var body: some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { reopenIfSaved() }, including: item.isReopenable ? .all : .subviews)
            .accessibilityActions {
                if item.isReopenable {
                    Button("Re-weigh") { reopenIfSaved() }
                }
                Button("Tag details") { showingDetails = true }
            }
            .contextMenu {
                Button("Tag details", systemImage: "info.circle") { showingDetails = true }
            }
            .sheet(isPresented: $showingDetails) {
                if let details = feed.tagDetails(for: item.id) {
                    TagDetailsSheet(details: details).feedSheet(feed)
                }
            }
            .help(Text("Scanned \(item.scannedAt, style: .time)"))
            #if os(macOS)
            .overlay {
                // A row that waits while the user types in another one.
                if feed.focus.hintedRow == item.id {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2)
                }
            }
            #else
            .listRowBackground(
                rowBackground.overlay {
                    if feed.focus.hintedRow == item.id {
                        RoundedRectangle(cornerRadius: layout == .table ? 12 : 24, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2)
                    }
                }
            )
            #endif
    }

    #if os(iOS)
    /// The table's focused row takes the selection tint.
    private var rowBackground: Color {
        layout == .table && feed.focusedRow == item.id
            ? Color(uiColor: .tintColor).opacity(0.15)
            : Color(uiColor: .secondarySystemGroupedBackground)
    }
    #endif

    @ViewBuilder private var content: some View {
        #if os(macOS)
        HStack(alignment: .center, spacing: 12) {
            header
            trailing.frame(width: Self.entryWidth, alignment: .leading)
        }
        .controlSize(.large)
        .frame(minHeight: 60)
        #else
        if layout == .table {
            tableContent
        } else {
            cardContent
        }
        #endif
    }

    #if os(iOS)
    /// Swatch 28 · title 150 · colour 112 · remaining 140 · status
    /// (flexible, the short readout, Cancel and Link to existing… under it)
    /// · entry or action pills; 12 apart, at least 76 high with the row's
    /// padding.
    private var tableContent: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                SwatchView(swatch: item.swatch, size: 28)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                Text(item.tableColorText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)
                Text(item.tableRemainingText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityHeader)
            .accessibilityValue([item.timeoutNote, feed.error(for: item.id)].compactMap { $0 }.joined(separator: " "))
            .contentShape(Rectangle())
            .onTapGesture {
                if !item.isReopenable { focusedField.wrappedValue = nil }
            }
            VStack(alignment: .leading, spacing: 2) {
                status.accessibilityHidden(true)
                if item.isEntry, let readout = feed.readout(for: item.id) {
                    Text(readout.short)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(readout.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                if item.offersCancel || !item.tableStatusActions.isEmpty {
                    RowActions(feed: feed, item: item, style: .compact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.isEntry {
                WeightEntry(feed: feed, item: item, focusedField: focusedField)
            } else if !item.tableTrailingActions.isEmpty {
                RowActions(feed: feed, item: item, style: .pills)
            }
        }
        .frame(minHeight: 56)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                // A tap outside the field lowers the number pad; a saved
                // row reopens instead.
                .onTapGesture {
                    if !item.isReopenable { focusedField.wrappedValue = nil }
                }
            if item.isEntry || !item.rowActions.isEmpty {
                trailing
            }
        }
    }
    #endif

    /// Swatch, title, colour line, status: one element for VoiceOver.
    private var header: some View {
        headerContent
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityHeader)
            // The timeout note and a failed host action sit in the header too.
            .accessibilityValue([item.timeoutNote, feed.error(for: item.id)].compactMap { $0 }.joined(separator: " "))
    }

    /// macOS: three equal columns. iOS: the colour line and the status
    /// stacked under the title.
    private var headerContent: some View {
        HStack(alignment: .center, spacing: 12) {
            SwatchView(swatch: item.swatch, size: 28)
            #if os(macOS)
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(item.detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            status.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            #else
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.headline).lineLimit(1)
                if !item.detailText.isEmpty {
                    Text(item.detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                status.padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                StatusSymbolView(symbol: item.statusSymbol, tint: item.statusTint)
                    #if os(iOS)
                    .font(layout == .table ? .system(size: 17) : nil)
                    #endif
                Text(item.statusText)
                    .foregroundStyle(item.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .font(.subheadline)
            if let note = item.timeoutNote {
                #if os(macOS)
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                #else
                Label {
                    Text(note).foregroundStyle(.secondary).lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.footnote)
                .padding(.top, 4)
                #endif
            }
            if let error = feed.error(for: item.id) {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2).help(error)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if item.isEntry {
            WeightEntry(feed: feed, item: item, focusedField: focusedField)
        } else if !item.rowActions.isEmpty {
            // A New spool or Created row, or a tag no spool carries.
            #if os(macOS)
            RowActions(feed: feed, item: item)
            #else
            RowActions(feed: feed, item: item, style: .card)
            #endif
        } else {
            // Saved, timed out or looking up: the space stays empty.
            Color.clear.frame(height: 1)
        }
    }

    /// A click on a saved row opens it again for a re-weigh.
    private func reopenIfSaved() {
        guard item.isReopenable else { return }
        Task { await feed.reopen(item.id) }
    }
}

/// A spinner while something runs, else the state's SF Symbol in its tint.
struct StatusSymbolView: View {
    let symbol: StatusSymbol
    let tint: StatusTint

    var body: some View {
        switch symbol {
        case .progress:
            ProgressView().controlSize(.small)
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(tint.color)
        }
    }
}

extension StatusTint {
    var color: Color {
        switch self {
        case .secondary: .secondary
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .gray: .gray
        }
    }
}

/// Weight field with its "g" unit, Net/Gross and Save, the readout under the
/// field, and on a revealed New spool or Created entry Cancel (Esc) and Link
/// to existing… (a New spool's Save creates the spool and records the
/// weight). macOS lays it out on one line (Tab goes field → mode → Save in
/// view order); iOS stacks it full width with the number pad, and beside the
/// iPad sidebar puts field · g · Net/Gross · Save on one line (the row shows
/// the readout, Cancel and Link under its status).
struct WeightEntry: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    #if os(macOS)
    /// The weight is the one custom-sized type: 22 pt at the default size.
    @ScaledMetric(relativeTo: .largeTitle) private var weightSize: CGFloat = 22
    #else
    @Environment(\.feedLayout) private var layout
    #endif

    var body: some View {
        #if os(macOS)
        lineBody
        #else
        if layout == .table { tableBody } else { stackedBody }
        #endif
    }

    private var modePicker: some View {
        let id = item.id
        return Picker("Mode", selection: Binding(get: { feed.mode(for: id) }, set: { feed.setMode($0, for: id) })) {
            Text("Net").tag(Intent.WeightMode.net)
            Text("Gross").tag(Intent.WeightMode.gross)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Net: filament only. Gross: spool on the scale, core included.")
    }

    @ViewBuilder private var readout: some View {
        if let readout = feed.readout(for: item.id) {
            Text(readout.text)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(readout.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
    }

    private var saveHelp: String {
        item.savesNewSpool ? "Create the spool in Bambuddy from the tag and save the weight" : "Save the weight"
    }

    #if os(macOS)
    private var lineBody: some View {
        let id = item.id
        let mode = feed.mode(for: id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    field(id: id, mode: mode)
                    Text("g")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                modePicker
                    .frame(width: 150)
                    .onKeyPress(.leftArrow) {
                        feed.setMode(.net, for: id)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        feed.setMode(.gross, for: id)
                        return .handled
                    }
                Button {
                    Task { await feed.save(id) }
                } label: {
                    Text(feed.saveTitle(for: id)).font(.headline).frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!feed.canSave(id))
                .help(saveHelp)
            }
            .disabled(feed.isSaving(id))
            HStack(spacing: 8) {
                readout
                Spacer(minLength: 0)
                if item.offersCancel || !item.rowActions.isEmpty {
                    RowActions(feed: feed, item: item, style: .compact)
                }
            }
        }
    }

    private func field(id: FeedRow.ID, mode: Intent.WeightMode) -> some View {
        TextField(
            FeedItem.weightFieldLabel(mode: mode),
            text: Binding(get: { feed.weightText(for: id) }, set: { feed.setWeightText($0, for: id) }),
            prompt: Text(item.suggestion(mode: mode).map(String.init) ?? "")
        )
        .labelsHidden()
        .accessibilityLabel(FeedItem.weightFieldLabel(mode: mode))
        .textFieldStyle(.plain)
        .font(.system(size: weightSize, weight: .bold, design: .rounded).monospacedDigit())
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 8)
        .frame(width: 96, height: 34)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            // The focus ring: a plain field draws none of its own.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    focusedField.wrappedValue == id ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                    lineWidth: focusedField.wrappedValue == id ? 2 : 0.5
                )
        }
        .focused(focusedField, equals: id)
        // AppKit selects the field's text on focus, so the first keystroke
        // replaces the suggestion.
        .onSubmit { Task { await feed.save(id) } }
        // Esc hides a revealed entry; a known spool's stays.
        .onExitCommand(perform: item.offersCancel ? { feed.hideEntry(id) } : nil)
        .takesRevealFocus(feed: feed, id: id, focusedField: focusedField)
    }
    #else
    /// Field 100 × 44 · `g` · Net/Gross 120 × 34 · Save 44 high, 8 apart;
    /// ⇥ goes field → mode → Save, Return in the field saves.
    private var tableBody: some View {
        let id = item.id
        return HStack(spacing: 8) {
            PadWeightField(feed: feed, item: item, focusedField: focusedField)
            Text("g")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            modePicker
                .frame(width: 120, height: 34)
            Button {
                Task { await feed.save(id) }
            } label: {
                Text(feed.saveTitle(for: id))
                    .font(.headline)
                    .frame(minWidth: 52, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
            .disabled(!feed.canSave(id))
            .help("Save (\u{2318}S)")
            .accessibilityHint(saveHelp)
        }
        .disabled(feed.isSaving(id))
    }

    /// Field, Net / Gross, readout, Save, then Cancel and Link to existing…
    /// as capsules on a revealed New spool or Created entry; 10 pt apart.
    private var stackedBody: some View {
        let id = item.id
        return VStack(alignment: .leading, spacing: 10) {
            PhoneWeightField(feed: feed, item: item, focusedField: focusedField)
                // The value stays on one line at the largest sizes.
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .disabled(feed.isSaving(id))
            modePicker
                .disabled(feed.isSaving(id))
            readout
            Button {
                Task { await feed.save(id) }
            } label: {
                Text(feed.saveTitle(for: id))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!feed.canSave(id))
            .accessibilityHint(saveHelp)
            if item.offersCancel || !item.rowActions.isEmpty {
                RowActions(feed: feed, item: item, style: .card)
            }
        }
    }
    #endif
}

#if os(iOS)
/// The iPad table's weight field: 100 × 44, the value right-aligned at 28 pt.
/// Taking the keyboard selects the value, as on the iPhone.
struct PadWeightField: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    @ScaledMetric(relativeTo: .largeTitle) private var weightSize: CGFloat = 28
    @ViewState private var selection: TextSelection?

    var body: some View {
        let id = item.id
        let mode = feed.mode(for: id)
        let focused = focusedField.wrappedValue == id
        TextField(
            FeedItem.weightFieldLabel(mode: mode),
            text: Binding(get: { feed.weightText(for: id) }, set: { feed.setWeightText($0, for: id) }),
            selection: $selection,
            prompt: Text("0").foregroundStyle(.tertiary)
        )
        .labelsHidden()
        .accessibilityLabel(FeedItem.weightFieldLabel(mode: mode))
        .keyboardType(.numberPad)
        .font(.system(size: weightSize, weight: .bold, design: .rounded).monospacedDigit())
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
        .focused(focusedField, equals: id)
        .onSubmit { Task { await feed.save(id) } }
        .padding(.horizontal, 10)
        .frame(width: 100, height: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { focusedField.wrappedValue = id }
        .selectsAllOnFocus(feed: feed, id: id, focused: focused, mode: mode, selection: $selection)
        .hidesRevealedEntryOnEscape(feed: feed, item: item)
        .takesRevealFocus(feed: feed, id: id, focusedField: focusedField)
    }
}

extension View {
    /// The first key replaces the value: taking the keyboard selects it, and
    /// so does a mode switch of an untouched suggestion.
    func selectsAllOnFocus(
        feed: FeedViewModel, id: FeedRow.ID, focused: Bool, mode: Intent.WeightMode,
        selection: Binding<TextSelection?>
    ) -> some View {
        // After the field has placed its caret from the tap.
        let selectAll = {
            let text = feed.weightText(for: id)
            Task { @MainActor in
                selection.wrappedValue = TextSelection(range: text.startIndex..<text.endIndex)
            }
        }
        return onChange(of: focused) { _, now in
            if now { selectAll() } else { selection.wrappedValue = nil }
        }
        .onChange(of: mode) {
            // A converted suggestion stays selected; a typed number keeps its caret.
            if focused && !feed.draft(for: id).touched { selectAll() }
        }
    }

    /// Esc on a hardware keyboard hides a revealed entry; a known spool's stays.
    func hidesRevealedEntryOnEscape(feed: FeedViewModel, item: FeedItem) -> some View {
        onKeyPress(.escape) {
            guard item.offersCancel else { return .ignored }
            feed.hideEntry(item.id)
            return .handled
        }
    }
}

/// The iPhone's weight field: 64 high, full width, the value with its unit
/// and the mode word inside. Taking the keyboard selects the value, so the
/// first key on the number pad replaces it.
struct PhoneWeightField: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    @ScaledMetric(relativeTo: .largeTitle) private var weightSize: CGFloat = 34
    @ViewState private var selection: TextSelection?

    var body: some View {
        let id = item.id
        let mode = feed.mode(for: id)
        let focused = focusedField.wrappedValue == id
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField(
                FeedItem.weightFieldLabel(mode: mode),
                text: Binding(get: { feed.weightText(for: id) }, set: { feed.setWeightText($0, for: id) }),
                selection: $selection,
                prompt: Text("0").foregroundStyle(.tertiary)
            )
            .labelsHidden()
            .accessibilityLabel(FeedItem.weightFieldLabel(mode: mode))
            .keyboardType(.numberPad)
            .font(.system(size: weightSize, weight: .bold, design: .rounded).monospacedDigit())
            .fixedSize()
            .focused(focusedField, equals: id)
            Text("g")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Text(FeedItem.modeWord(mode))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(.rect(cornerRadius: 14))
        // A tap anywhere in the box, not only on the digits, takes the pad.
        .onTapGesture { focusedField.wrappedValue = id }
        .selectsAllOnFocus(feed: feed, id: id, focused: focused, mode: mode, selection: $selection)
        .hidesRevealedEntryOnEscape(feed: feed, item: item)
        .takesRevealFocus(feed: feed, id: id, focusedField: focusedField)
    }
}
#endif

extension View {
    /// Save with weight… / Set weight… focus the row before its field
    /// exists, so the feed's change of focus finds no field: the field takes
    /// the keyboard as it appears.
    func takesRevealFocus(feed: FeedViewModel, id: FeedRow.ID, focusedField: FocusState<FeedRow.ID?>.Binding) -> some View {
        onAppear {
            if feed.focusedField == id { focusedField.wrappedValue = id }
        }
    }
}

#if os(macOS)
/// The Flipper item and the Bambuddy item, each a symbol and a phrase with
/// its reason in the tooltip, and the button the state offers.
struct StatusBar: View {
    let flipper: StatusItem
    let bambuddy: StatusItem
    let perform: (StatusItem.Action) -> Void

    var body: some View {
        HStack(spacing: 16) {
            item(flipper)
            item(bambuddy)
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func item(_ item: StatusItem) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                StatusSymbolView(symbol: item.symbol, tint: item.tint)
                Text(item.text)
            }
            .help(item.detail ?? item.text)
            .accessibilityElement(children: .combine)
            if let action = item.action {
                button(action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func button(_ action: StatusItem.Action) -> some View {
        if action == .settings {
            SettingsLink { Text(action.title) }
        } else {
            Button(action.title) { perform(action) }
        }
    }
}
#endif
#endif
