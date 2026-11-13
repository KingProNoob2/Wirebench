import SwiftUI
import WirebenchCore
import WirebenchLibrary
import WirebenchModel

/// The block picker, shown from the toolbar.
///
/// Deliberately a popover with a search field and category sections rather than a menu: there are
/// 140-odd block types, and hunting through nested menus for one is exactly the interaction macOS
/// apps avoid. This mirrors the object-library pickers people already know.
struct BlockPaletteView: View {
    /// Called with the chosen block-type GUID.
    let onInsert: (UUID) -> Void
    let dismiss: () -> Void
    /// The macro sheets this page may call, and the interface blocks it still lacks (a macro page only).
    var macros: [String] = []
    var interfaces: [MacroInterface.Kind] = []
    var onInsertMacro: (String) -> Void = { _ in }
    var onInsertInterface: (MacroInterface.Kind) -> Void = { _ in }
    /// What has been learned about which blocks get added, and what the next one is being added to. *All Blocks*
    /// lists the likeliest first, and Return adds the first one.
    var usage = BlockUsageModel()
    var context = BlockUsageModel.Context()

    @State private var query = ""
    @State private var selectedCategory: String?

    /// A row of the block list: a macro entry, by position, or a block.
    private enum RowID: Hashable {
        case macro(Int)
        case block(UUID)
    }

    /// The row Return adds, until the arrow keys or a click move it.
    @State private var highlighted: RowID?

    private enum Pane: Hashable {
        case search
        case blocks
    }
    @FocusState private var focus: Pane?

    /// What the category list can select: *All Blocks*, or one category by its catalogue name. Not a bare `String?`
    /// because the uncategorised blocks' category is the empty string, which has to stay distinct from "all".
    private enum CategoryChoice: Hashable {
        case all
        case named(String)
    }

    // The naming, ordering and search live in `BlockPaletteSearch`, which every frontend shares.
    nonisolated static func displayName(for category: String) -> String { BlockPaletteSearch.displayName(for: category) }
    nonisolated static func ordered(_ items: [BlockTypeInfo]) -> [BlockTypeInfo] { BlockPaletteSearch.ordered(items) }
    nonisolated static func relevance(of info: BlockTypeInfo, for query: String) -> Int? {
        BlockPaletteSearch.relevance(of: info, for: query)
    }
    nonisolated static func ranked(_ items: [BlockTypeInfo], for query: String, chances: [UUID: Double]? = nil,
                                   byChanceWithoutQuery: Bool = false) -> [BlockTypeInfo] {
        BlockPaletteSearch.ranked(items, for: query, chances: chances, byChanceWithoutQuery: byChanceWithoutQuery)
    }

    private var categories: [String] { BlockPaletteSearch.categories() }

    private var matches: [BlockTypeInfo] {
        let scope = BlockTypeCatalog.all.filter { info in
            BlockPaletteSearch.isOffered(info) && (selectedCategory == nil || info.category == selectedCategory)
        }
        // Only *All Blocks* is ordered by what is likely: a category is for browsing, and stays alphabetical.
        return Self.ranked(scope, for: query, chances: usage.probabilities(for: scope, in: context),
                           byChanceWithoutQuery: selectedCategory == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The same glass search field as the sidebar's. Typing straight away is the point of the picker, so the
            // caret starts here and returns here after a category is chosen; the down arrow moves the keys to the list.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search blocks", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .search)
                    .onSubmit(insertHighlighted)
                    .onKeyPress(.downArrow) {
                        focus = .blocks
                        return .handled
                    }
                if isSearching {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassPanel(Capsule())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 0) {
                categoryList
                Divider()
                blockList
            }
        }
        .frame(width: 460, height: 380)
        .task { focus = .search }
        .onAppear { highlighted = defaultHighlight }
        // The highlight follows the search and the category until the user moves it.
        .onChange(of: defaultHighlight) { _, row in highlighted = row }
        // A click on a category takes the caret out of the search field; it goes straight back, so typing carries on
        // and Return still adds the highlighted row (the category's first).
        .onChange(of: selectedCategory) {
            DispatchQueue.main.async { focus = .search }
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The row Return adds before anything moves the highlight. With a search, the best match — the macros come
    /// first in the list, so they come first here. With none, in *All Blocks*, the block the model expects next
    /// (a macro is never the suggestion). In a category, its first row.
    private func defaultHighlight(macros: [MacroEntry], blocks: [BlockTypeInfo]) -> RowID? {
        let firstMacro: RowID? = macros.isEmpty ? nil : .macro(0)
        let firstBlock: RowID? = blocks.first.map { .block($0.guid) }
        if !isSearching && selectedCategory == nil { return firstBlock }
        return firstMacro ?? firstBlock
    }

    private var defaultHighlight: RowID? { defaultHighlight(macros: macroEntries, blocks: matches) }

    /// Adds the highlighted row — or, if it has left the list since, the one that would be highlighted now.
    private func insertHighlighted() {
        let macros = macroEntries
        let blocks = matches
        let row: RowID?
        switch highlighted {
        case .macro(let index)? where macros.indices.contains(index): row = highlighted
        case .block(let guid)? where blocks.contains(where: { $0.guid == guid }): row = highlighted
        default: row = defaultHighlight(macros: macros, blocks: blocks)
        }
        switch row {
        case .macro(let index)?: insert(macros[index])
        case .block(let guid)?:
            onInsert(guid)
            dismiss()
        case nil: break
        }
    }

    private func insert(_ entry: MacroEntry) {
        switch entry {
        case .call(let sheet): onInsertMacro(sheet)
        case .interface(let kind): onInsertInterface(kind)
        }
        dismiss()
    }

    private var categorySelection: Binding<CategoryChoice?> {
        Binding(get: { selectedCategory.map(CategoryChoice.named) ?? .all },
                set: { choice in
                    if case .named(let name)? = choice { selectedCategory = name } else { selectedCategory = nil }
                })
    }

    /// A sidebar list, so the system draws the rows and their selection the way every other sidebar looks.
    private var categoryList: some View {
        List(selection: categorySelection) {
            Text("All Blocks").tag(CategoryChoice.all)
            Section("Categories") {
                ForEach(categories, id: \.self) { category in
                    Text(Self.displayName(for: category)).tag(CategoryChoice.named(category))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 160)
    }

    private enum MacroEntry {
        case call(String)
        case interface(MacroInterface.Kind)

        var title: String {
            switch self {
            case .call(let sheet): return MacroInterface.name(ofSheet: sheet)
            case .interface(let kind): return kind == .inputs ? "Macro Inputs" : "Macro Outputs"
            }
        }

        var detail: String {
            switch self {
            case .call: return "Call this macro"
            case .interface(let kind): return kind == .inputs ? "The pins this macro takes in" : "The pins this macro gives back"
            }
        }
    }

    /// The user's own macros and the interface blocks of the macro page being edited, for the current search.
    private var macroEntries: [MacroEntry] {
        guard selectedCategory == nil || selectedCategory == "Macro" else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = interfaces.map(MacroEntry.interface) + macros.map(MacroEntry.call)
        return all.filter { q.isEmpty || $0.title.lowercased().contains(q) }
    }

    /// What a row carries when it is dragged onto the sheet (`AppModel.placePaletteItem` reads it back).
    private func dragPayload(for entry: MacroEntry) -> String {
        switch entry {
        case .call(let sheet): return AppModel.palettePayload(macro: sheet)
        case .interface(let kind): return AppModel.palettePayload(interface: kind)
        }
    }

    private func macroRow(_ entry: MacroEntry) -> some View {
        // Not a `Button`, and no SwiftUI gesture: `PaletteDragSource` takes the mouse, so a click adds and a drag drags.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Macro").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay { PaletteDragSource(payload: dragPayload(for: entry), title: entry.title) { insert(entry) } }
        .accessibilityAddTraits(.isButton)
    }

    /// A list the system draws: its selection is the highlight, blue while the list has the keys and grey while the
    /// search does, and ↑ ↓ and Return work as they do in any list. A click on a row still adds it.
    private var blockList: some View {
        Group {
            let macros = macroEntries
            let blocks = matches
            if blocks.isEmpty && macros.isEmpty {
                Text("No blocks match “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Which block is the model's suggestion: the first of *All Blocks*, with nothing typed.
                let suggested = (!isSearching && selectedCategory == nil) ? blocks.first?.guid : nil
                List(selection: $highlighted) {
                    ForEach(Array(macros.enumerated()), id: \.offset) { index, entry in
                        macroRow(entry).tag(RowID.macro(index))
                    }
                    ForEach(blocks, id: \.guid) { info in
                        blockRow(info, isSuggested: info.guid == suggested).tag(RowID.block(info.guid))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .blocks)
                .onKeyPress(.return) {
                    insertHighlighted()
                    return .handled
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func blockRow(_ info: BlockTypeInfo, isSuggested: Bool) -> some View {
        // Not a `Button`, and no SwiftUI gesture: `PaletteDragSource` takes the mouse, so a click adds and a drag drags.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(BlockPaletteSearch.displayBlockName(for: info))
                Text(info.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSuggested {
                // The model's pick, and what Return adds.
                Label("Suggested", systemImage: "return")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if selectedCategory == nil {
                // With one flat list, the category is worth showing on the row itself.
                Text(Self.displayName(for: info.category))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay {
            PaletteDragSource(payload: AppModel.palettePayload(block: info.guid),
                              title: BlockPaletteSearch.displayBlockName(for: info)) {
                onInsert(info.guid)
                dismiss()
            }
        }
        .accessibilityAddTraits(.isButton)
        .help("\(info.delphiClass) — \(Self.displayName(for: info.category))")
    }
}
