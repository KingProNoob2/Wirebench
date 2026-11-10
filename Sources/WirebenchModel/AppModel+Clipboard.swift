import Foundation
import WirebenchCore
import WirebenchLibrary

/// Blocks taken by Copy, with the wires that ran between them. Held by the model, so both frontends share one clipboard
/// behaviour; it lives as long as the app, and a paste can be repeated.
package struct BlockClipboard: Equatable {
    package var modules: [PCCModule]
    package var connections: [Connection]
    package var paramConnections: [Connection]
    /// How many times it has been pasted, so each paste lands a step further along rather than on top of the last.
    package var pasteCount = 0
}

extension AppModel {
    /// The blocks on the sheet being shown that are selected. A selection survives a change of page, and must not copy
    /// something that cannot be seen. A macro's `Inputs` and `Outputs` are left out: a sheet has one of each.
    private var copyableSelection: [PCCModule] {
        guard let project else { return [] }
        let ids = selectedModuleIds.union(selectedModuleId.map { [$0] } ?? [])
        return project.modules.filter { ids.contains($0.id) && $0.page == selectedPage && MacroInterface.kind(of: $0) == nil }
    }

    public var canCopy: Bool { !copyableSelection.isEmpty }
    public var canPaste: Bool { clipboard != nil }

    /// Takes the selected blocks, and the wires between them, for `paste`. Wires to blocks outside the selection stay behind.
    @discardableResult
    public func copySelection() -> Bool {
        guard let project else { return false }
        let modules = copyableSelection
        guard !modules.isEmpty else { return false }
        let inside = Set(modules.map(\.id))
        func within(_ connection: Connection) -> Bool { inside.contains(connection.inModuleId) && inside.contains(connection.outModuleId) }
        clipboard = BlockClipboard(modules: modules,
                                   connections: project.inConnections.filter(within),
                                   paramConnections: project.paramConnections.filter(within))
        return true
    }

    /// Copy, then delete.
    @discardableResult
    public func cutSelection() -> Bool {
        guard copySelection() else { return false }
        deleteSelectedModule()
        return true
    }

    /// Puts the copied blocks on the sheet being shown, each a little further along than the last paste, with new ids, new
    /// names where the old ones are taken, the wires among them, and the pasted blocks selected. One undoable edit.
    @discardableResult
    public func paste() -> [Int] {
        guard var clip = clipboard, var project else { return [] }
        clip.pasteCount += 1
        clipboard = clip
        let shift = Double(clip.pasteCount) * (snapToGrid ? GridSnap.step : 24)

        var nextId = BlockFactory.nextId(in: project)
        var order = BlockFactory.nextOrder(in: project, page: selectedPage)
        var idMap: [Int: Int] = [:]
        var copies: [PCCModule] = []
        for module in clip.modules {
            var copy = module
            idMap[module.id] = nextId
            copy.id = nextId
            nextId += 1
            copy.page = selectedPage
            copy.x += shift
            copy.y += shift
            copy.order = order
            order += 10
            copy.name = Self.uniqueName(like: module.name, among: project.modules + copies)
            copies.append(copy)
        }
        // A block copied out of a container with the container follows it; without it, it goes onto the sheet.
        for index in copies.indices {
            guard let text = copies[index].rawAttributes["IN_CONTAINER"], let old = Int(text) else { continue }
            if let moved = idMap[old] {
                copies[index].rawAttributes["IN_CONTAINER"] = "\(moved)"
            } else {
                copies[index].rawAttributes.removeValue(forKey: "IN_CONTAINER")
                copies[index].rawAttributes.removeValue(forKey: "ARM")
            }
        }
        func renumbered(_ connections: [Connection]) -> [Connection] {
            connections.compactMap { connection in
                guard let from = idMap[connection.outModuleId], let to = idMap[connection.inModuleId] else { return nil }
                var copy = connection
                copy.outModuleId = from
                copy.inModuleId = to
                return copy
            }
        }
        project.modules.append(contentsOf: copies)
        project.inConnections.append(contentsOf: renumbered(clip.connections))
        project.paramConnections.append(contentsOf: renumbered(clip.paramConnections))
        self.project = project

        let ids = copies.map(\.id)
        selectedModuleIds = Set(ids)           // before the lead, so choosing the lead keeps the group
        selectedModuleId = ids.first
        isDocumentEdited = true
        runtimeDidChangeStructure()
        return ids
    }

    /// `name` with its trailing number replaced by the lowest one that is free: `Counter1` becomes `Counter2`.
    private static func uniqueName(like name: String, among modules: [PCCModule]) -> String {
        let taken = Set(modules.map(\.name))
        var base = name
        while let last = base.last, last.isNumber { base.removeLast() }
        if base.isEmpty { base = name }
        var index = 1
        while taken.contains("\(base)\(index)") { index += 1 }
        return "\(base)\(index)"
    }
}
