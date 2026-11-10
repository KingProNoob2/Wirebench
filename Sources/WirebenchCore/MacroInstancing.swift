import Foundation

/// Gives every call of a macro its own copy of the macro's sheet.
///
/// Dirigo expands a macro by inlining its sheet at each call, so two calls of `*Adder` have two sets of
/// blocks, each with its own state. A sheet is stored once in the project, so engines and the compiler that
/// read it as it stands would let every call share one set. This decides which calls get a copy.
///
/// The first call that reaches a sheet keeps the original sheet — so a project with one call per macro is
/// left exactly as it was, ids and all. Every further call gets a clone named `Name#n`: its calls are
/// renamed to `Name#n`, and its sheet's page is `*Name#n`. Everything that finds a sheet by `*<MACRO_NAME>`
/// then finds the right one without knowing anything about instances. Clones are made recursively, since a
/// clone's own calls are calls too.
public enum MacroInstancing {
    /// A macro call on some sheet: `key` identifies the module (unique in the project), `order` is its
    /// `ORDER` (the first call in `(order, key)` order keeps the original sheet).
    public struct Call: Sendable {
        public var key: Int
        public var order: Int
        public var target: String
        public init(key: Int, order: Int, target: String) { self.key = key; self.order = order; self.target = target }
    }

    /// A sheet: the calls on it, and how many modules it holds (what a clone of it costs).
    public struct Sheet: Sendable {
        public var calls: [Call]
        public var size: Int
        public init(calls: [Call], size: Int) { self.calls = calls; self.size = size }
    }

    /// A call, as seen from the sheet instance it is on: `owner` is `""` for the original sheets and the
    /// main pages, and a clone's name for a call inside that clone.
    public struct CallSite: Hashable, Sendable {
        public var owner: String
        public var key: Int
        public init(owner: String, key: Int) { self.owner = owner; self.key = key }
    }

    public struct Clone: Equatable, Sendable {
        /// The instance name, which becomes the clone's calls' `MACRO_NAME` and its page `*name`.
        public var name: String
        /// The original sheet's page, lowercased.
        public var sheet: String
    }

    public struct Plan: Sendable {
        /// The copies to make, outermost first.
        public var clones: [Clone] = []
        /// The `MACRO_NAME` a call takes instead of its own; absent when it keeps it.
        public var renames: [CallSite: String] = [:]
        /// The original sheets (lowercased pages) the program reaches. A call on any other `*` sheet is never run, so
        /// it must not push its inputs into a sheet that a real call is using.
        public var reached: Set<String> = []
        public var isEmpty: Bool { clones.isEmpty }
    }

    /// - Parameters:
    ///   - topCalls: calls on the pages the program starts from (any order).
    ///   - sheets: every `*` sheet by lowercased page (`"*adder"`).
    ///   - budget: how many more modules may be created; a call whose copy would not fit stays shared.
    public static func plan(topCalls: [Call], sheets: [String: Sheet], budget: Int = .max) -> Plan {
        var plan = Plan()
        var claimed: Set<String> = []
        var remaining = budget
        var serial = 0

        func visit(owner: String, calls: [Call], path: [String]) {
            for call in calls.sorted(by: { ($0.order, $0.key) < ($1.order, $1.key) }) {
                let page = "*" + call.target.lowercased()
                guard let sheet = sheets[page], !path.contains(page) else { continue }
                if claimed.insert(page).inserted {
                    visit(owner: "", calls: sheet.calls, path: path + [page])
                } else if sheet.size <= remaining {
                    remaining -= sheet.size
                    serial += 1
                    let name = "\(call.target)#\(serial)"
                    plan.renames[CallSite(owner: owner, key: call.key)] = name
                    plan.clones.append(Clone(name: name, sheet: page))
                    visit(owner: name, calls: sheet.calls, path: path + [page])
                }
            }
        }
        visit(owner: "", calls: topCalls, path: [])
        plan.reached = claimed
        return plan
    }

    /// The project with each shared sheet cloned per call, as `plan` says. A project with no repeated call
    /// comes back unchanged. Fresh module ids start past the project's highest.
    public static func instanced(_ project: PCCProject) -> PCCProject {
        var sheets: [String: Sheet] = [:]
        var topCalls: [Call] = []
        for module in project.modules {
            let page = module.page.lowercased()
            if page.hasPrefix("*") {
                var sheet = sheets[page] ?? Sheet(calls: [], size: 0)
                sheet.size += 1
                if let target = MacroCalls.target(of: module) {
                    sheet.calls.append(Call(key: module.id, order: module.order, target: target))
                }
                sheets[page] = sheet
            } else if let target = MacroCalls.target(of: module) {
                topCalls.append(Call(key: module.id, order: module.order, target: target))
            }
        }
        let plan = plan(topCalls: topCalls, sheets: sheets)
        let strayCall = project.modules.contains {
            $0.page.hasPrefix("*") && !plan.reached.contains($0.page.lowercased()) && MacroCalls.target(of: $0) != nil
        }
        guard !plan.isEmpty || strayCall else { return project }

        var result = project
        var nextId = (project.modules.map(\.id).max() ?? 0) + 1
        func rename(_ module: inout PCCModule, owner: String, key: Int) {
            if let name = plan.renames[CallSite(owner: owner, key: key)] {
                module.rawAttributes["MACRO_NAME"] = name
            }
        }
        for index in result.modules.indices {
            rename(&result.modules[index], owner: "", key: result.modules[index].id)
            // A call on a sheet nothing calls is left pointing at no sheet, so it neither feeds nor reads one.
            let page = result.modules[index].page.lowercased()
            if page.hasPrefix("*"), !plan.reached.contains(page), let target = MacroCalls.target(of: result.modules[index]) {
                result.modules[index].rawAttributes["MACRO_NAME"] = target + "#off"
            }
        }
        for clone in plan.clones {
            var idMap: [Int: Int] = [:]
            let sheet = project.modules.filter { $0.page.lowercased() == clone.sheet }
            // Ids first, then the copies: a module can name another module by id (a container's member names its
            // `IN_CONTAINER`), and that id has to be the *copy's* by the time the copy is made — which it is not
            // while the loop that assigns them is still running.
            for module in sheet {
                idMap[module.id] = nextId
                nextId += 1
            }
            for module in sheet {
                var copy = module
                copy.id = idMap[module.id]!
                copy.page = "*" + clone.name
                if let text = copy.rawAttributes["IN_CONTAINER"], let owner = Int(text), let mapped = idMap[owner] {
                    copy.rawAttributes["IN_CONTAINER"] = String(mapped)
                }
                rename(&copy, owner: clone.name, key: module.id)
                result.modules.append(copy)
            }
            func copies(of connections: [Connection]) -> [Connection] {
                connections.compactMap { connection in
                    guard let from = idMap[connection.outModuleId], let to = idMap[connection.inModuleId] else { return nil }
                    var copy = connection
                    copy.outModuleId = from
                    copy.inModuleId = to
                    return copy
                }
            }
            result.inConnections += copies(of: project.inConnections)
            result.paramConnections += copies(of: project.paramConnections)
        }
        return result
    }
}
