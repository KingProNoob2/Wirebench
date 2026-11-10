import Foundation
import Observation
import WirebenchCore
import WirebenchLibrary

// The block reference: what each block does, its pins and its rules, from Dirigo's own library manual, in English and in the original Czech.
// The pages are data (`HelpData`, made by tools/gen_help_data.py); `HelpModel` is the window's state, which the SwiftUI and Qt apps both draw.

public enum HelpLanguage: String, CaseIterable, Sendable, Identifiable {
    case english = "en", czech = "cs"
    public var id: String { rawValue }
    /// Its name in its own language, for the switch.
    public var label: String { self == .english ? "English" : "Čeština" }

    /// The words the window itself uses.
    public var strings: HelpStrings {
        switch self {
        case .english:
            return HelpStrings(title: "Block Reference", search: "Search blocks", pins: "Inputs, outputs and parameters",
                               abbreviation: "Pin", kind: "Kind", dataType: "Type", name: "Name", description: "Description", defaultValue: "Default",
                               input: "input", output: "output", parameter: "parameter", notes: "Notes", formula: "Library description",
                               noResults: "No block matches.", noPage: "There is no reference page for this block.",
                               notTranslated: "This block is not in the Czech manual; the English page is shown.",
                               pickABlock: "Pick a block from the list.", source: "Source: Dirigo's library manual")
        case .czech:
            return HelpStrings(title: "Přehled bloků", search: "Hledat bloky", pins: "Vstupy, výstupy a parametry",
                               abbreviation: "Zkratka", kind: "Typ", dataType: "Datový typ", name: "Název", description: "Popis", defaultValue: "Výchozí hodnota",
                               input: "vstup", output: "výstup", parameter: "parametr", notes: "Popis činnosti", formula: "Popis v knihovně",
                               noResults: "Žádný blok neodpovídá.", noPage: "Pro tento blok není stránka nápovědy.",
                               notTranslated: "Tento blok není v české příručce; zobrazena je anglická stránka.",
                               pickABlock: "Vyberte blok ze seznamu.", source: "Zdroj: knihovna modulů Dirigo")
        }
    }
}

public struct HelpStrings: Sendable, Equatable {
    public var title, search, pins, abbreviation, kind, dataType, name, description, defaultValue: String
    public var input, output, parameter, notes, formula, noResults, noPage, notTranslated, pickABlock, source: String

    /// "input", "output" or "parameter" as the language says it.
    public func kind(_ canonical: String) -> String {
        switch canonical { case "input": return input; case "output": return output; case "parameter": return parameter; default: return canonical }
    }
}

public struct HelpPin: Sendable, Equatable, Decodable {
    public var abbreviation, kind, dataType, name, text, defaultValue: String

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        abbreviation = try c.decode(String.self); kind = try c.decode(String.self); dataType = try c.decode(String.self)
        name = try c.decode(String.self); text = try c.decode(String.self); defaultValue = try c.decode(String.self)
    }
}

public struct HelpTable: Sendable, Equatable, Decodable {
    public var head: [String]
    public var rows: [[String]]
}

public struct HelpEntry: Sendable, Equatable, Decodable, Identifiable {
    public var name: String
    public var category: String
    /// The sub-group inside `Main` ("Timers", "Switches"…), empty elsewhere.
    public var group: String
    /// What the block is, in a few words.
    public var title: String
    /// The library's own one-line description (a formula for most), always in English.
    public var formula: String
    public var pins: [HelpPin]
    public var notes: [String]
    public var tables: [HelpTable]
    public var id: String { name }
}

/// A run of blocks under one heading in the list.
public struct HelpSection: Sendable, Equatable, Identifiable {
    public var title: String
    public var entries: [HelpEntry]
    public var id: String { title }
}

/// One language's pages.
public struct HelpLibrary: Sendable {
    private struct Document: Decodable {
        var categories: [String]
        var blurbs: [String: String]
        var entries: [HelpEntry]
    }

    public let entries: [HelpEntry]
    /// Categories in the manual's order, with its one-line description of each (Czech only).
    public let categories: [String]
    public let blurbs: [String: String]
    private let byName: [String: HelpEntry]

    init(json: String) {
        let document = (try? JSONDecoder().decode(Document.self, from: Data(json.utf8))) ?? Document(categories: [], blurbs: [:], entries: [])
        entries = document.entries
        categories = document.categories
        blurbs = document.blurbs
        byName = Dictionary(document.entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static let english = HelpLibrary(json: HelpData.english)
    private static let czech = HelpLibrary(json: HelpData.czech)
    public static func library(_ language: HelpLanguage) -> HelpLibrary { language == .english ? english : czech }

    /// The page for a block type, by its name in the app (any case); the older manual's `Dbn…` is the app's `D3N…`.
    public func entry(named name: String) -> HelpEntry? {
        byName[name.lowercased()] ?? byName[name.lowercased().replacingOccurrences(of: "dbn", with: "d3n")]
    }

    /// Pages matching every word of `query` in a name, title or text, best matches (by name) first. All of them for an empty query.
    public func search(_ query: String) -> [HelpEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        var scored: [(HelpEntry, Int)] = []
        for e in entries {
            let name = e.name.lowercased()
            let haystack = ([e.name, e.title, e.formula, e.category, e.group] + e.notes + e.pins.flatMap { [$0.abbreviation, $0.name, $0.text] })
                .joined(separator: " ").lowercased()
            var score = 0
            var all = true
            for w in words {
                if name == w { score += 10 } else if name.hasPrefix(w) { score += 6 } else if name.contains(w) { score += 4 }
                else if e.title.lowercased().contains(w) { score += 2 } else if haystack.contains(w) { score += 1 } else { all = false; break }
            }
            if all { scored.append((e, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }.map(\.0)
    }

    /// The list grouped the way the manual is: by category, and `Main` by its sub-groups.
    public func sections(of entries: [HelpEntry]) -> [HelpSection] {
        var order: [String] = []
        var grouped: [String: [HelpEntry]] = [:]
        for e in entries.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            let title = e.group.isEmpty ? e.category : "\(e.category) › \(e.group)"
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(e)
        }
        let rank = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1, $0) })
        return order.sorted { a, b in
            let (ra, rb) = (rank[a.components(separatedBy: " › ")[0]] ?? 99, rank[b.components(separatedBy: " › ")[0]] ?? 99)
            return ra != rb ? ra < rb : a < b
        }.map { HelpSection(title: $0, entries: grouped[$0] ?? []) }
    }
}

/// The help window's state: the language, what is searched for, and which page is open.
@Observable
public final class HelpModel: @unchecked Sendable {
    public var language: HelpLanguage {
        didSet { if language != oldValue { defaults.set(language.rawValue, forKey: "help.language") } }
    }
    public var query = ""
    /// The block type whose page is open, by name. May be one that has no page, which the window says.
    public var selected: String?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = HelpLanguage(rawValue: defaults.string(forKey: "help.language") ?? "") ?? .english
    }

    public var strings: HelpStrings { language.strings }

    /// The open page in the chosen language; the English one for a block the Czech manual lacks.
    public var entry: HelpEntry? {
        guard let selected else { return nil }
        return HelpLibrary.library(language).entry(named: selected) ?? HelpLibrary.library(.english).entry(named: selected)
    }

    /// Whether the open page is English only because the chosen language has none.
    public var isFallback: Bool {
        guard language != .english, let selected else { return false }
        return HelpLibrary.library(language).entry(named: selected) == nil && HelpLibrary.library(.english).entry(named: selected) != nil
    }

    /// The list for the current search, grouped. In Czech, blocks the manual lacks are not listed.
    public var sections: [HelpSection] {
        let library = HelpLibrary.library(language)
        return library.sections(of: library.search(query))
    }

    /// Opens the page for a block type (what a block's "Help" asks for) and clears the search so it is in the list.
    public func show(blockNamed name: String) {
        query = ""
        selected = name
    }

    /// The page to open for a block of the project: its type's name.
    public static func blockName(of module: PCCModule) -> String {
        BlockTypeCatalog.info(forGuid: module.guid)?.blockName ?? ""
    }
}
