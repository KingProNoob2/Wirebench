import Foundation

/// Which modules are macro call sites, and how deep macros nest.
///
/// A macro is a sheet (`*Name`) that another sheet — or another macro's sheet — calls by `MACRO_NAME`. The
/// sheet's own `Inputs`, `Outputs` and `Params` interface modules carry a `MACRO_NAME` too (`Inputs`…), which
/// is why those names are not calls.
public enum MacroCalls {
    private static let interfaceNames: Set<String> = ["inputs", "outputs", "params"]

    /// The macro a module calls, or `nil` when it is not a call site. The page it sits on does not matter: a
    /// call on a `*` sheet is a nested macro.
    public static func target(of module: PCCModule) -> String? {
        guard let name = module.rawAttributes["MACRO_NAME"], !name.isEmpty,
              !interfaceNames.contains(name.lowercased()) else { return nil }
        return name
    }

    /// How many macros are stacked: 0 with none, 1 when only main pages call, 2 when a macro calls another.
    /// A sheet that calls itself, or a loop of sheets, is counted once.
    public static func nestingDepth(in modules: [PCCModule]) -> Int {
        var callsFrom: [String: [String]] = [:]
        for module in modules {
            if let name = target(of: module) { callsFrom[module.page.lowercased(), default: []].append("*" + name.lowercased()) }
        }
        func depth(of page: String, seen: Set<String>) -> Int {
            guard !seen.contains(page) else { return 0 }
            return (callsFrom[page] ?? []).map { 1 + depth(of: $0, seen: seen.union([page])) }.max() ?? 0
        }
        let top = Set(modules.map { $0.page.lowercased() }).filter { !$0.hasPrefix("*") }
        return top.map { depth(of: $0, seen: []) }.max() ?? 0
    }

    /// How many times the engines run the "bridge, wires, bridge" sweep per propagation. One level is one
    /// sweep; each further level adds a trip down (caller → inner inputs) and a trip back (inner outputs →
    /// caller), so a value crosses the whole stack within one propagation instead of one level per tick.
    public static func sweeps(forDepth depth: Int) -> Int { depth <= 1 ? 1 : 2 * depth }
}
