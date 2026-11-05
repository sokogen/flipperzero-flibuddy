import FliBuddyCore
import SwiftUI

#if os(iOS)
/// The Spools tab (ios spec, "Spools"): Bambuddy's inventory, read-only. The
/// list with search, the scope and the sort and material menu; a picked spool
/// opens in an inspector beside the iPad sidebar, in a sheet otherwise. It
/// loads each time it comes on screen, on pull to refresh, and after the
/// feed's writes (`SpoolsViewModel.observe()`, started by the app).
public struct SpoolsView: View {
    @Bindable var model: SpoolsViewModel
    let openSettings: () -> Void
    @Environment(\.feedLayout) private var layout

    public init(model: SpoolsViewModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
    }

    public var body: some View {
        content
            .navigationTitle(SpoolsViewModel.title)
            .searchable(text: $model.query, prompt: SpoolsViewModel.searchPrompt)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            // Not `.task`: leaving the tab would cancel the load, and the
            // cancelled request would read as Bambuddy unreachable.
            .onAppear { Task { await model.refresh() } }
            .inspector(isPresented: presented(inInspector: true)) {
                NavigationStack {
                    if let detail = model.selectedDetail {
                        SpoolDetailView(detail: detail, close: { model.selection = nil })
                    }
                }
                .inspectorColumnWidth(FeedLayout.inspectorWidth)
            }
            .sheet(isPresented: presented(inInspector: false)) {
                if let detail = model.selectedDetail {
                    NavigationStack {
                        SpoolDetailView(detail: detail, close: { model.selection = nil })
                    }
                    .presentationDetents([.medium, .large])
                }
            }
    }

    /// The detail is up in the inspector (beside the sidebar) or the sheet.
    private func presented(inInspector: Bool) -> Binding<Bool> {
        Binding(
            get: { layout.opensSpoolInInspector == inInspector && model.selectedDetail != nil },
            set: { if !$0, layout.opensSpoolInInspector == inInspector { model.selection = nil } }
        )
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .loading:
            ProgressView(SpoolsViewModel.loadingTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let state):
            SpoolsUnavailableView(state: state, perform: perform)
        case .list:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Picker("Scope", selection: $model.scope) {
                    ForEach(SpoolsViewModel.Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                if let notice = model.staleNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(SpoolsViewModel.Action.retry.title) { perform(.retry) }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 4))
                }
            }
            if let empty = model.emptyResult {
                Section {
                    SpoolsUnavailableView(state: empty, perform: perform)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(model.rows) { row in
                        Button {
                            model.selection = row.id
                        } label: {
                            SpoolRowView(row: row, showsChevron: !layout.opensSpoolInInspector)
                        }
                        .foregroundStyle(.primary)
                        .listRowBackground(
                            layout.opensSpoolInInspector && model.selection == row.id
                                ? Color.accentColor.opacity(0.2) : nil
                        )
                    }
                } footer: {
                    if let footer = model.footer { Text(footer) }
                }
            }
        }
        .listStyle(.insetGrouped)
        // The scope control sits close over the rows it filters.
        .listSectionSpacing(.compact)
        .refreshable { await model.refresh() }
    }

    private var menu: some View {
        Menu {
            Section(SpoolsViewModel.sortTitle) {
                Picker(SpoolsViewModel.sortTitle, selection: $model.sort) {
                    ForEach(SpoolsViewModel.Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section(SpoolsViewModel.materialTitle) {
                Picker(SpoolsViewModel.materialTitle, selection: $model.material) {
                    Text(SpoolsViewModel.allMaterialsTitle).tag(String?.none)
                    ForEach(model.materials, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Label(
                SpoolsViewModel.menuTitle,
                systemImage: model.isFiltering
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .disabled(model.content != .list)
    }

    private func perform(_ action: SpoolsViewModel.Action) {
        if action == .openSettings {
            openSettings()
        } else {
            Task { await model.perform(action) }
        }
    }
}

/// A row: swatch, title, colour and brand, what is left and when it was
/// updated; `Low`, `Archived` and the tag glyph trailing. VoiceOver reads the
/// view model's one sentence.
struct SpoolRowView: View {
    let row: SpoolsViewModel.Row
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            SwatchView(swatch: row.swatch, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.headline)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(row.detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if row.isLow { WordBadge(word: SpoolsViewModel.lowWord, tint: .orange) }
            if row.isArchived { WordBadge(word: SpoolsViewModel.archivedWord, tint: .secondary) }
            if row.hasTag {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// `Low` or `Archived`: the word in a tinted capsule; never colour alone.
struct WordBadge: View {
    let word: String
    let tint: Color

    var body: some View {
        Text(word)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 7))
    }
}

/// A Spools state in place of the list or its rows.
struct SpoolsUnavailableView: View {
    let state: SpoolsViewModel.Unavailable
    let perform: (SpoolsViewModel.Action) -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(state.title)
            } icon: {
                Image(systemName: state.systemImage)
                    .foregroundStyle(state.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        } description: {
            Text(state.message)
        } actions: {
            if let action = state.action {
                if action == .showAllMaterials {
                    Button(action.title) { perform(action) }
                } else {
                    Button(action.title) { perform(action) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        }
    }
}

/// The read-only detail: swatch, title, colour and brand, the gauge, today's
/// feed line, every fact Bambuddy keeps, and Open in Bambuddy for edits.
struct SpoolDetailView: View {
    let detail: SpoolsViewModel.Detail
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    private typealias Detail = SpoolsViewModel.Detail

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    SwatchView(swatch: detail.swatch, size: 64)
                    Text(detail.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                    if let subtitle = detail.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.gaugeText)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        if detail.isLow {
                            Text(SpoolsViewModel.lowWord)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Text(detail.percentText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Gauge(value: detail.fraction) {
                        EmptyView()
                    }
                    .gaugeStyle(.linearCapacity)
                    .tint(detail.isLow ? Color.orange : Color.accentColor)
                    .labelsHidden()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    [detail.gaugeText, detail.percentText, detail.isLow ? "low" : nil].compactMap { $0 }
                        .joined(separator: ", ")
                )
            }
            if let today = detail.today {
                Section(Detail.todayTitle) {
                    HStack(spacing: 8) {
                        StatusSymbolView(symbol: today.symbol, tint: today.tint)
                        Text(today.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section(Detail.detailsTitle) {
                ForEach(detail.facts, id: \.label) { fact in
                    LabeledContent(fact.label) {
                        Text(fact.value)
                            .font(fact.monospaced ? .body.monospaced() : .body)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                if let url = detail.bambuddyURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(Detail.openTitle, systemImage: "arrow.up.right.square")
                    }
                }
            } footer: {
                Text(Detail.footer)
            }
        }
        .navigationTitle(detail.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
            }
        }
    }
}
#endif
