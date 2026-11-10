import Foundation

/// `If` and `Switch` as *containers*: one block that owns the blocks of its branches.
///
/// Legacy Dirigo has no such thing — an `If` is a marker, and what it governs is whatever blocks come after it in
/// execution order, up to a matching `EndIf` marker (likewise `Switch` … `Case` … `Default` … `EndSwitch`). Keeping
/// that on the sheet means hand-maintaining execution order and a row of label blocks. Here the project instead
/// records the nesting directly, as attributes:
///
/// * the `If` / `Switch` module carries `CONTAINER="1"`; a `Switch` also has `CASES` — its cases in run order,
///   `|`-separated, each a permanent id and its value list, e.g. `c1:1, 5..7|c2:9` — and `DEFAULT="1"` when it has
///   a default arm;
/// * a block inside one carries `IN_CONTAINER` (the container's module id) and `ARM` — `then`, `else`, a case's
///   id, or `default`.
///
/// A case's id never changes, so editing its values or reordering the cases keeps every block in the case it was
/// put in. Files written before ids existed have bare value lists (`1, 5..7|9`); those cases read as `case0`,
/// `case1`, … — the `ARM` values those files used — and get real ids the next time the cases are edited.
///
/// `expanded(_:)` turns that back into the legacy form: the container module is kept as the `If` / `Switch`, and
/// the marker blocks are created around its members, which are renumbered to follow it in execution order. The
/// simulator runs the expanded project, and the legacy export writes it, so what runs here is what Dirigo would run.
/// A project with no containers comes back untouched.
public enum ConstructContainers {
    public static let ifGuid = UUID(uuidString: "6B0C4496-86AB-4113-A91C-4022FE6DC7CA")!
    public static let switchGuid = UUID(uuidString: "D99B35AC-31D2-40B0-B529-12C8C9B356BB")!
    static let elseGuid = UUID(uuidString: "76D0013D-0CF1-406C-8366-16E299A0F7EC")!
    static let endIfGuid = UUID(uuidString: "506CF9FC-364B-47AF-8E3F-965F94224B06")!
    static let caseGuid = UUID(uuidString: "4D83C589-DE5F-4FB1-9222-F5836722340B")!
    static let defaultGuid = UUID(uuidString: "A99FFBCE-0803-4939-AB9D-DE413F16A36F")!
    static let endSwitchGuid = UUID(uuidString: "0E92235F-6CE0-4FEC-8EB4-556846E16695")!

    static let attributeNames = ["CONTAINER", "CASES", "DEFAULT", "IN_CONTAINER", "ARM"]

    /// A branch of a container.
    public struct Arm: Equatable, Sendable {
        /// What a member's `ARM` holds.
        public var id: String
        /// What the sheet shows.
        public var label: String
    }

    public static func isContainer(_ module: PCCModule) -> Bool {
        module.rawAttributes["CONTAINER"] == "1" && (module.guid == ifGuid || module.guid == switchGuid)
    }

    /// One case of a switch container.
    public struct Case: Equatable, Sendable {
        /// What a member's `ARM` holds. Permanent.
        public var id: String
        /// The values it matches, as Dirigo's `Case` block takes them: `1, 5..7, 9`.
        public var values: String

        public init(id: String, values: String) {
            self.id = id
            self.values = values
        }
    }

    /// A switch container's cases, in run order.
    public static func cases(of module: PCCModule) -> [Case] {
        guard let text = module.rawAttributes["CASES"], !text.isEmpty else { return [] }
        return text.components(separatedBy: "|").enumerated().map { index, entry in
            // A value list never holds a colon, so one marks an id. Without one it is a pre-id file.
            guard let colon = entry.firstIndex(of: ":") else { return Case(id: "case\(index)", values: entry) }
            return Case(id: String(entry[..<colon]), values: String(entry[entry.index(after: colon)...]))
        }
    }

    public static func setCases(_ cases: [Case], of module: inout PCCModule) {
        module.rawAttributes["CASES"] = cases.map { "\($0.id):\($0.values)" }.joined(separator: "|")
    }

    /// An id no case of `existing` has, for a case being added.
    public static func newCaseId(among existing: [Case]) -> String {
        let used = Set(existing.map(\.id))
        var n = existing.count + 1
        while used.contains("c\(n)") { n += 1 }
        return "c\(n)"
    }

    /// Where a member of a branch that no longer exists goes: `default` if the switch has one, otherwise out of
    /// the container (`nil`). An `If`'s branches never go away, so its members always stay.
    public static func rehome(arm: String, in container: PCCModule) -> String? {
        if arms(of: container).contains(where: { $0.id == arm }) { return arm }
        return container.rawAttributes["DEFAULT"] == "1" ? "default" : nil
    }

    /// The branches of a container, in the order they run.
    public static func arms(of module: PCCModule) -> [Arm] {
        if module.guid == ifGuid {
            return [Arm(id: "then", label: "Then"), Arm(id: "else", label: "Else")]
        }
        var arms = cases(of: module).map {
            Arm(id: $0.id, label: "Case \($0.values.trimmingCharacters(in: .whitespaces))")
        }
        if module.rawAttributes["DEFAULT"] == "1" { arms.append(Arm(id: "default", label: "Default")) }
        return arms
    }

    /// The container a block is in, if it names a real one and a real branch of it.
    public static func container(of module: PCCModule, in modules: [PCCModule]) -> PCCModule? {
        guard let text = module.rawAttributes["IN_CONTAINER"], let id = Int(text), id != module.id,
              let arm = module.rawAttributes["ARM"],
              let owner = modules.first(where: { $0.id == id }), isContainer(owner),
              arms(of: owner).contains(where: { $0.id == arm }) else { return nil }
        return owner
    }

    /// Whether putting `module` into `container` would make a container hold itself.
    public static func wouldCycle(moving moduleId: Int, into containerId: Int, in modules: [PCCModule]) -> Bool {
        var cursor: Int? = containerId
        var steps = 0
        while let id = cursor, steps <= modules.count {
            if id == moduleId { return true }
            cursor = modules.first(where: { $0.id == id })
                .flatMap { Int($0.rawAttributes["IN_CONTAINER"] ?? "") }
            steps += 1
        }
        return false
    }

    /// The project with every container written out as legacy marker blocks. See the type's note.
    public static func expanded(_ project: PCCProject) -> PCCProject {
        guard project.modules.contains(where: isContainer) else { return project }

        var members: [Int: [String: [PCCModule]]] = [:]
        var topLevel: [PCCModule] = []
        for module in project.modules {
            if let owner = container(of: module, in: project.modules),
               !wouldCycle(moving: module.id, into: owner.id, in: project.modules) {
                members[owner.id, default: [:]][module.rawAttributes["ARM"] ?? "", default: []].append(module)
            } else {
                topLevel.append(module)
            }
        }

        let firstMarkerId = (project.modules.map(\.id).max() ?? 0) + 1
        var nextId = firstMarkerId
        func marker(_ guid: UUID, _ name: String, like owner: PCCModule, values: String? = nil) -> PCCModule {
            var module = PCCModule(id: nextId, guid: guid, name: name, x: owner.x, y: owner.y, order: 0,
                                   threadId: owner.threadId, page: owner.page)
            if let values { module.rawAttributes["VALUES"] = values }
            nextId += 1
            return module
        }
        func clean(_ module: PCCModule) -> PCCModule {
            var copy = module
            for name in attributeNames { copy.rawAttributes.removeValue(forKey: name) }
            return copy
        }
        func inRunOrder(_ modules: [PCCModule]) -> [PCCModule] {
            modules.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        }

        /// A module, then — if it is a container — its branches between the markers, in order.
        func emit(_ module: PCCModule, thread: Int, into out: inout [PCCModule]) {
            var placed = clean(module)
            placed.threadId = thread
            out.append(placed)
            guard isContainer(module) else { return }
            let armMembers = members[module.id] ?? [:]
            func emitArm(_ id: String) {
                for child in inRunOrder(armMembers[id] ?? []) { emit(child, thread: thread, into: &out) }
            }
            if module.guid == ifGuid {
                emitArm("then")
                if !(armMembers["else"] ?? []).isEmpty {
                    out.append(marker(elseGuid, "Else", like: module))
                    emitArm("else")
                }
                out.append(marker(endIfGuid, "EndIf", like: module))
            } else {
                for item in cases(of: module) {
                    out.append(marker(caseGuid, "Case", like: module, values: item.values))
                    emitArm(item.id)
                }
                if module.rawAttributes["DEFAULT"] == "1" {
                    out.append(marker(defaultGuid, "Default", like: module))
                    emitArm("default")
                }
                out.append(marker(endSwitchGuid, "EndSwitch", like: module))
            }
        }

        // Order is per thread. Only the threads that hold a container are renumbered, and their blocks keep their
        // relative order, so the project's other threads are written exactly as they were.
        let threadsWithContainers = Set(project.modules.filter(isContainer).map(\.threadId))
        var emitted: [Int: [PCCModule]] = [:]
        for module in inRunOrder(topLevel) {
            emit(module, thread: module.threadId, into: &emitted[module.threadId, default: []])
        }
        var placed: [Int: PCCModule] = [:]
        var markers: [PCCModule] = []
        for (threadId, list) in emitted {
            for (index, var module) in list.enumerated() {
                if threadsWithContainers.contains(threadId) { module.order = (index + 1) * 10 }
                if module.id < firstMarkerId { placed[module.id] = module } else { markers.append(module) }
            }
        }
        var output = project
        output.modules = project.modules.compactMap { placed[$0.id] } + markers.sorted { $0.id < $1.id }
        return output
    }
}
