import Testing
import Foundation
@testable import DirigoApp
import DirigoLibrary

/// The palette's category names. Dirigo stores most groups as `Main\…`, and eight catalogued types
/// carry no category at all — which used to render as a *blank* section header that read as an empty
/// list.
@Suite("Block palette")
struct BlockPaletteTests {

    @Test("The Main\\ prefix is dropped from a group name")
    func stripsTheMainPrefix() {
        #expect(BlockPaletteView.displayName(for: "Main\\Arrays") == "Arrays")
        #expect(BlockPaletteView.displayName(for: "Main\\Comparators") == "Comparators")
        // `Main\Switches` and `Switches` are both real groups, so this one keeps a readable prefix
        // rather than colliding with the other.
        #expect(BlockPaletteView.displayName(for: "Main\\Switches") == "Main Switches")
    }

    @Test("Simple categories are left alone")
    func leavesSimpleNames() {
        for name in ["Bool", "Communication", "I/O", "Macro", "Vars", "Visual"] {
            #expect(BlockPaletteView.displayName(for: name) == name)
        }
    }

    @Test("An uncategorised block reads as General, never as a blank header")
    func namesTheEmptyCategory() {
        #expect(BlockPaletteView.displayName(for: "") == "General")
        // The catalog really does contain such blocks, which is how the blank header appeared.
        #expect(BlockTypeCatalog.all.contains { $0.category.isEmpty })
    }

    @Test("No two groups end up with the same displayed name")
    func displayedNamesAreUnique() {
        var seen: Set<String> = []
        for info in BlockTypeCatalog.all {
            let shown = BlockPaletteView.displayName(for: info.category)
            #expect(!shown.isEmpty, "\(info.blockName) would show a blank group")
            seen.insert(shown)
        }
        // Duplicates are fine (many raw categories map to one label only if they are equal), but the
        // count of distinct raw categories must equal the count of distinct labels.
        let raw = Set(BlockTypeCatalog.all.map(\.category))
        #expect(seen.count == raw.count, "two categories collapsed into one label: \(seen.sorted())")
    }

    @Test("Blocks are listed alphabetically, not in implementation order")
    func listsAlphabetically() {
        let ordered = BlockPaletteView.ordered(BlockTypeCatalog.all)
        #expect(ordered.count == BlockTypeCatalog.all.count, "sorting must not drop anything")
        let names = ordered.map(\.blockName)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        // And the catalog's own order really is different, so this is a real change.
        #expect(names != BlockTypeCatalog.all.map(\.blockName))
    }

    private func find(_ name: String) -> BlockTypeInfo {
        BlockTypeCatalog.all.first { $0.blockName == name }!
    }

    @Test("An exact block name outranks everything else")
    func exactNameWins() {
        let ranked = BlockPaletteView.ranked(BlockTypeCatalog.all, for: "and")
        #expect(ranked.first?.blockName == "And", "got \(ranked.prefix(3).map(\.blockName))")
        // Blocks whose name merely contains "and", and blocks matching only in prose, come after.
        let andIndex = ranked.firstIndex { $0.blockName == "And" }!
        for weaker in ["Comparator", "DateTime", "8xAI"] {
            if let i = ranked.firstIndex(where: { $0.blockName == weaker }) {
                #expect(i > andIndex, "\(weaker) should rank below And")
            }
        }
    }

    @Test("Name matches outrank matches found only in the summary")
    func nameBeatsSummary() {
        #expect(BlockPaletteView.relevance(of: find("And"), for: "and") == 0)
        #expect(BlockPaletteView.relevance(of: find("Comparator"), for: "and") == 5,
                "Comparator only matches \"and\" in its summary")
        // A class-name match sits in between.
        let byClass = BlockPaletteView.relevance(of: find("Comparator"), for: "TMComparator")
        #expect(byClass == 3)
    }

    @Test("Non-matches are dropped, and an empty query keeps the alphabet")
    func filtersAndFallsBack() {
        #expect(BlockPaletteView.relevance(of: find("And"), for: "zzzz") == nil)
        let all = BlockPaletteView.ranked(BlockTypeCatalog.all, for: "   ")
        #expect(all.map(\.blockName) == BlockPaletteView.ordered(BlockTypeCatalog.all).map(\.blockName))
    }

    @Test("Category names are searchable through their displayed form")
    func findsByDisplayedCategory() {
        // "Main\Timers" displays as "Timers", so that is what a search has to match.
        let ranked = BlockPaletteView.ranked(BlockTypeCatalog.all, for: "timers")
        #expect(!ranked.isEmpty)
        #expect(ranked.allSatisfy { BlockPaletteView.displayName(for: $0.category) == "Timers" })
    }
}
