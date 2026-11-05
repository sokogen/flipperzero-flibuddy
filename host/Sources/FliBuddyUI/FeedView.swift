import FliBuddyCore
import SwiftUI

// The watch has its own compact views (Watch/).
#if !os(watchOS)
/// The session feed: one row per scanned tag, newest first, with the status
/// bar under it on macOS and the connection banner over it on iOS (beside
/// the iPad sidebar both states are in the sidebar instead). In Spoolman
/// mode an explanation replaces the feed.
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
    /// The tile grid's width, which sets its columns.
    @ViewState private var gridWidth: CGFloat = 0
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
                if layout.showsBanner {
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
            // The iPad's top tab bar stays.
            .toolbarVisibility(
                layout.hidesTabBarWhileTyping && focusedField != nil ? .hidden : .automatic, for: .tabBar
            )
            .sensoryFeedback(trigger: feed.haptic) { _, haptic in
                switch haptic?.kind {
                case .success: .success
                case .error: .error
                case nil: nil
                }
            }
            #endif
            .modifier(ClearConfirmation(isPresented: confirmingClear, centred: isCentredClear) {
                Task { await feed.clear() }
            })
            .toolbar {
                #if os(iOS)
                // Icon only, at the leading end of the bar; beside the iPad
                // sidebar Clear feed is in the sidebar. ⌘⌫ is a menu command.
                if layout.showsBanner {
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

    /// The iPad asks in a centred alert.
    private var isCentredClear: Bool {
        #if os(iOS)
        layout.centresClearConfirmation
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
        if layout.showsTiles { tileGrid } else { cardList }
        #endif
    }

    #if os(iOS)
    /// The iPad's tiles (iPad page): at least 300 wide, at most three to a
    /// row, top-aligned; the focused row scrolls into view above the
    /// keyboard.
    private var tileGrid: some View {
        let column = GridItem(.flexible(), spacing: FeedLayout.tileSpacing, alignment: .top)
        let columns = Array(repeating: column, count: FeedLayout.tileColumns(width: gridWidth))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: FeedLayout.tileSpacing) {
                    ForEach(feed.items) { item in
                        FeedRowView(feed: feed, item: item, focusedField: $focusedField)
                            .id(item.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(.horizontal, FeedLayout.tileMargin)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
/// alert on the iPad. Same copy everywhere.
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
/// on the iPad a compact tile of the same parts.
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
            // The card's background in the List; a tile draws its own.
            .listRowBackground(
                Color(uiColor: .secondarySystemGroupedBackground).overlay {
                    if feed.focus.hintedRow == item.id {
                        Self.cardShape.strokeBorder(.tint, lineWidth: 2)
                    }
                }
            )
            #endif
    }

    #if os(iOS)
    private static let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private static let tileShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
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
        if layout.showsTiles {
            tileContent
        } else {
            cardContent
        }
        #endif
    }

    #if os(iOS)
    /// The iPad tile (iPad page): padding 14, 10 between the header and the
    /// entry; the field's focus ring marks the focused row, the 2 pt outline
    /// a row that waits.
    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .contentShape(Rectangle())
                .onTapGesture {
                    if !item.isReopenable { focusedField.wrappedValue = nil }
                }
            if item.isEntry {
                WeightEntry(feed: feed, item: item, focusedField: focusedField)
            } else if !item.rowActions.isEmpty {
                RowActions(feed: feed, item: item, style: .tile)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Self.tileShape)
        .overlay {
            if feed.focus.hintedRow == item.id {
                Self.tileShape.strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(.contextMenuPreview, Self.tileShape)
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
    /// stacked under the title; a tile's swatch is 24, 10 from the text.
    private var headerContent: some View {
        HStack(alignment: .center, spacing: isTile ? 10 : 12) {
            SwatchView(swatch: item.swatch, size: isTile ? 24 : 28)
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
            // A tag no spool carries (New, Link), or a spool added here the
            // Flipper asked to relink (Link).
            #if os(macOS)
            RowActions(feed: feed, item: item)
            #else
            RowActions(feed: feed, item: item, style: .card)
            #endif
        } else {
            // Saved, added, timed out or looking up: the space stays empty.
            Color.clear.frame(height: 1)
        }
    }

    /// An iPad tile rather than an iPhone card or a Mac line.
    private var isTile: Bool {
        #if os(iOS)
        layout.showsTiles
        #else
        false
        #endif
    }

    /// A click on a saved or added row opens it again for a weight.
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

/// Weight field with its "g" unit, Net/Gross and Save, and the readout under
/// the field. macOS lays it out on one line (Tab goes field → mode → Save in
/// view order); the iPhone stacks it full width with the number pad; an iPad
/// tile puts the short readout inside the field and Net/Gross beside Save.
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
        if layout.showsTiles { tileBody } else { stackedBody }
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

    private let saveHelp = "Save the weight"

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
                    // With the button's sides, at least 64 wide (macOS page).
                    Text(feed.saveTitle(for: id)).font(.headline).frame(minWidth: 40)
                }
                .saveButtonStyle()
                .disabled(!feed.canSave(id))
                .help(saveHelp)
            }
            .disabled(feed.isSaving(id))
            readout
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
        .takesFeedFocusOnAppear(feed: feed, id: id, focusedField: focusedField)
    }
    #else
    /// The field (52 high, the short readout inside it), then Net/Gross
    /// and Save (36 high, at least 80 wide) on one row; 8 apart. ⇥ goes
    /// field → mode → Save, Return in the field saves.
    private var tileBody: some View {
        let id = item.id
        return VStack(alignment: .leading, spacing: 8) {
            PhoneWeightField(feed: feed, item: item, focusedField: focusedField, isTile: true)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            HStack(spacing: 8) {
                modePicker
                Button {
                    Task { await feed.save(id) }
                } label: {
                    Text(feed.saveTitle(for: id))
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 56, minHeight: 22)
                }
                .saveButtonStyle()
                .disabled(!feed.canSave(id))
                .help("Save (\u{2318}S)")
                .accessibilityHint(saveHelp)
            }
        }
        .disabled(feed.isSaving(id))
    }

    /// Field, Net / Gross, readout, Save; 10 pt apart.
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
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            // 44 high: tinted, the weight above it is the focus.
            .saveButtonStyle()
            .controlSize(.large)
            .disabled(!feed.canSave(id))
            .accessibilityHint(saveHelp)
        }
    }
    #endif
}

#if os(iOS)
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
}

/// The iPhone's weight field: 64 high, full width, the value with its unit
/// and the mode word inside. An iPad tile's is 52 high with the short
/// readout in the mode word's place. Taking the keyboard selects the value,
/// so the first key on the number pad replaces it.
struct PhoneWeightField: View {
    let feed: FeedViewModel
    let item: FeedItem
    var focusedField: FocusState<FeedRow.ID?>.Binding
    var isTile = false
    @ScaledMetric(relativeTo: .largeTitle) private var phoneWeightSize: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var tileWeightSize: CGFloat = 30
    @ViewState private var selection: TextSelection?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isTile ? 12 : 14)
    }

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
            .font(
                .system(size: isTile ? tileWeightSize : phoneWeightSize, weight: .bold, design: .rounded)
                    .monospacedDigit()
            )
            .fixedSize()
            .focused(focusedField, equals: id)
            .onSubmit { Task { await feed.save(id) } }
            Text("g")
                .font((isTile ? Font.title3 : .title2).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            trailing(mode: mode)
        }
        .padding(.horizontal, isTile ? 14 : 16)
        .frame(height: isTile ? 52 : 64)
        .background(Color(uiColor: .tertiarySystemFill), in: shape)
        .overlay {
            if focused {
                shape.strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(shape)
        // A tap anywhere in the box, not only on the digits, takes the pad.
        .onTapGesture { focusedField.wrappedValue = id }
        .selectsAllOnFocus(feed: feed, id: id, focused: focused, mode: mode, selection: $selection)
        .takesFeedFocusOnAppear(feed: feed, id: id, focusedField: focusedField)
    }

    /// The mode word on the iPhone; on a tile "Saves 590 g" or a red "Below
    /// core", which VoiceOver reads in full.
    @ViewBuilder private func trailing(mode: Intent.WeightMode) -> some View {
        if isTile {
            if let readout = feed.readout(for: item.id), !readout.tile.isEmpty {
                Text(readout.tile)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(readout.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .accessibilityLabel(readout.text)
            }
        } else {
            Text(FeedItem.modeWord(mode))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
#endif

extension View {
    /// A reopened row (a re-weigh, or the first weight of an added spool)
    /// is focused before its field exists, so the feed's change of focus
    /// finds no field: the field takes the keyboard as it appears.
    func takesFeedFocusOnAppear(feed: FeedViewModel, id: FeedRow.ID, focusedField: FocusState<FeedRow.ID?>.Binding) -> some View {
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
