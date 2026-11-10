import Foundation
import WirebenchCore
import WirebenchLibrary

/// How the block picker names, orders and searches the block catalogue. Pure functions over catalogue data, so every
/// frontend lists blocks the same way.
public enum BlockPaletteSearch {
    /// Whether the block picker (and the agent's search) offers a type. The bare macro types would insert a block with no name and no pins, the
    /// macro rows insert working ones; and `SystemCmd` is not a block to put on a sheet any more but an entry of the PLC configuration
    /// (`PLCConfiguration`), which is edited from *Build ▸ PLC Configuration*.
    public nonisolated static func isOffered(_ info: BlockTypeInfo) -> Bool {
        info.guid != MacroInterface.callGUID && info.guid != MacroInterface.interfaceGUID && info.guid != SystemCmdBlock.guid
    }

    /// A category as it should read.
    ///
    /// Dirigo files most blocks under `Main\…`, and a handful carry no category at all — the prefix
    /// is noise in a list of one-word groups, and the empty category rendered as a *blank* header,
    /// which looked like an empty section rather than a group of uncategorised blocks.
    public nonisolated static func displayName(for category: String) -> String {
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

    /// Alphabetical, always: the catalog's own order is the order blocks were implemented in, which
    /// means nothing to someone looking one up.
    public nonisolated static func ordered(_ items: [BlockTypeInfo]) -> [BlockTypeInfo] {
        items.sorted { $0.blockName.localizedCaseInsensitiveCompare($1.blockName) == .orderedAscending }
    }

    /// How well a block answers the query. Lower is better; `nil` means it does not match at all.
    ///
    /// Sorting results alphabetically put `8xAI` above `And` for a search for "and" — every match
    /// was equally good, so the alphabet decided. A name that *is* the query comes first now, then a
    /// name starting with it, then a name containing it, and only then matches found in the class,
    /// category or summary.
    public nonisolated static func relevance(of info: BlockTypeInfo, for query: String) -> Int? {
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

    /// Filters and orders by relevance. Matches that answer the query equally well go to the likelier one when
    /// `chances` says which that is (`BlockUsageModel`), then the shorter name — so `And` beats `AndSomething` —
    /// then the alphabet, so equal matches still come out predictably.
    ///
    /// With no query the list is alphabetical, unless `byChanceWithoutQuery`: then it is the likeliest first.
    public nonisolated static func ranked(_ items: [BlockTypeInfo], for query: String,
                                   chances: [UUID: Double]? = nil,
                                   byChanceWithoutQuery: Bool = false) -> [BlockTypeInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func likelier(_ a: BlockTypeInfo, _ b: BlockTypeInfo) -> Bool? {
            guard let chances, let x = chances[a.guid], let y = chances[b.guid], x != y else { return nil }
            return x > y
        }
        guard !q.isEmpty else {
            guard byChanceWithoutQuery, chances != nil else { return ordered(items) }
            return items.sorted { a, b in
                if let first = likelier(a, b) { return first }
                return a.blockName.localizedCaseInsensitiveCompare(b.blockName) == .orderedAscending
            }
        }
        return items
            .compactMap { info in relevance(of: info, for: q).map { ($0, info) } }
            .sorted { a, b in
                if a.0 != b.0 { return a.0 < b.0 }
                if let first = likelier(a.1, b.1) { return first }
                if a.1.blockName.count != b.1.blockName.count { return a.1.blockName.count < b.1.blockName.count }
                return a.1.blockName.localizedCaseInsensitiveCompare(b.1.blockName) == .orderedAscending
            }
            .map(\.1)
    }

    /// The catalogue's categories, alphabetical by how they read.
    public static func categories() -> [String] {
        var seen: [String] = []
        for info in BlockTypeCatalog.all where !seen.contains(info.category) {
            seen.append(info.category)
        }
        return seen.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }
}
