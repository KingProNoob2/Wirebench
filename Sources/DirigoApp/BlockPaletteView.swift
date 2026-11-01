import SwiftUI
import DirigoCore
import DirigoLibrary

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

    @State private var query = ""
    @State private var selectedCategory: String?
    @FocusState private var searchFocused: Bool

    /// A category as it should read.
    ///
    /// Dirigo files most blocks under `Main\…`, and a handful carry no category at all — the prefix
    /// is noise in a list of one-word groups, and the empty category rendered as a *blank* header,
    /// which looked like an empty section rather than a group of uncategorised blocks.
    /// `nonisolated` because it is a pure function over catalog data, with no view state behind it —
    /// and a `View`'s statics are main-actor isolated by default, which made this trap at runtime
    /// when a test called it off the main actor.
    nonisolated static func displayName(for category: String) -> String {
        if category.isEmpty { return "General" }
        guard category.hasPrefix("Main\\"),
              let leaf = category.split(separator: "\\").last else {
            return category
        }
        let short = String(leaf)
        // Two raw categories can share a leaf — `Switches` and `Main\Switches` both exist, holding
        // different blocks — so the prefix is only dropped when the short name is not already a
        // group of its own.
        let taken = BlockTypeCatalog.all.contains { $0.category == short }
        return taken ? "Main " + short : short
    }

    private var categories: [String] {
        var seen: [String] = []
        for info in BlockTypeCatalog.all where !seen.contains(info.category) {
            seen.append(info.category)
        }
        return seen.sorted {
            Self.displayName(for: $0).localizedCaseInsensitiveCompare(Self.displayName(for: $1)) == .orderedAscending
        }
    }

    /// Alphabetical, always: the catalog's own order is the order blocks were implemented in, which
    /// means nothing to someone looking one up.
    nonisolated static func ordered(_ items: [BlockTypeInfo]) -> [BlockTypeInfo] {
        items.sorted { $0.blockName.localizedCaseInsensitiveCompare($1.blockName) == .orderedAscending }
    }

    /// How well a block answers the query. Lower is better; `nil` means it does not match at all.
    ///
    /// Sorting results alphabetically put `8xAI` above `And` for a search for "and" — every match
    /// was equally good, so the alphabet decided. A name that *is* the query comes first now, then a
    /// name starting with it, then a name containing it, and only then matches found in the class,
    /// category or summary.
    nonisolated static func relevance(of info: BlockTypeInfo, for query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        let name = info.blockName.lowercased()
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if name.contains(q) { return 2 }
        if info.delphiClass.lowercased().contains(q) { return 3 }
        if displayName(for: info.category).lowercased().contains(q) { return 4 }
        if info.summary.lowercased().contains(q) { return 5 }
        return nil
    }

    /// Filters and orders by relevance, falling back to the alphabet — with the shorter name first,
    /// so `And` beats `AndSomething` — so equal matches still come out predictably.
    nonisolated static func ranked(_ items: [BlockTypeInfo], for query: String) -> [BlockTypeInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ordered(items) }
        return items
            .compactMap { info in relevance(of: info, for: q).map { ($0, info) } }
            .sorted { a, b in
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1.blockName.count != b.1.blockName.count { return a.1.blockName.count < b.1.blockName.count }
                return a.1.blockName.localizedCaseInsensitiveCompare(b.1.blockName) == .orderedAscending
            }
            .map(\.1)
    }

    private var matches: [BlockTypeInfo] {
        let scope = BlockTypeCatalog.all.filter { info in
            // The catalogue's bare `Macro` and `Macro IO` would insert a block with no name and no pins; the
            // macro rows insert working ones.
            info.guid != MacroInterface.callGUID && info.guid != MacroInterface.interfaceGUID &&
            (selectedCategory == nil || info.category == selectedCategory)
        }
        return Self.ranked(scope, for: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search blocks", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(insertTopResult)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
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
        // Typing straight away is the point of the picker, so the caret starts in the search field.
        .task { searchFocused = true }
    }

    /// Whether Return has something to insert: there is a query, and something matches it.
    private var hasTopResult: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && (!macroEntries.isEmpty || !matches.isEmpty)
    }

    /// Return in the search field inserts the first row of the list, which is the best match: macro
    /// rows come first in the list, so they come first here too.
    private func insertTopResult() {
        guard hasTopResult else { return }
        if let entry = macroEntries.first {
            insert(entry)
        } else if let info = matches.first {
            onInsert(info.guid)
            dismiss()
        }
    }

    private func insert(_ entry: MacroEntry) {
        switch entry {
        case .call(let sheet): onInsertMacro(sheet)
        case .interface(let kind): onInsertInterface(kind)
        }
        dismiss()
    }

    /// The row Return would insert, marked so the keyboard shortcut is not a guess.
    private func topResultBackground(_ isTop: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isTop && hasTopResult ? Color.accentColor.opacity(0.16) : .clear)
    }

    private var categoryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                categoryRow(nil, label: "All Blocks")
                ForEach(categories, id: \.self) { category in
                    categoryRow(category, label: Self.displayName(for: category))
                }
            }
            .padding(6)
        }
        .frame(width: 150)
    }

    private func categoryRow(_ category: String?, label: String) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack {
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selectedCategory == category ? Color.accentColor.opacity(0.22) : .clear)
            )
        }
        .buttonStyle(.plain)
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

    private func macroRow(_ entry: MacroEntry, isTop: Bool) -> some View {
        Button {
            insert(entry)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.tint(forCategory: "Macro")).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Macro").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(topResultBackground(isTop))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var blockList: some View {
        Group {
            if matches.isEmpty && macroEntries.isEmpty {
                Text("No blocks match “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // One flat alphabetical list. Grouping it by category produced headers that said
                    // nothing useful in "All Blocks" and broke the alphabet into runs.
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let macros = macroEntries
                        let blocks = matches
                        ForEach(Array(macros.enumerated()), id: \.offset) { index, entry in
                            macroRow(entry, isTop: index == 0)
                        }
                        ForEach(blocks, id: \.guid) { info in
                            blockRow(info, isTop: macros.isEmpty && info.guid == blocks.first?.guid)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func blockRow(_ info: BlockTypeInfo, isTop: Bool) -> some View {
        Button {
            onInsert(info.guid)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Theme.tint(forCategory: info.category))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.blockName)
                    Text(info.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // With one flat list, the category is worth showing on the row itself.
                if selectedCategory == nil {
                    Text(Self.displayName(for: info.category))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(topResultBackground(isTop))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(info.delphiClass) — \(Self.displayName(for: info.category))")
    }
}
