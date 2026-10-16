import Foundation
import CoreGraphics
import DirigoCore
import DirigoLibrary

/// Building macros in the editor: a `*` page, its `Inputs` / `Outputs` interface, and calls of it from other pages.
///
/// The rules live in `MacroInterface` / `PCCProject` (DirigoCore), where they are testable without a view; these
/// methods only place things on the canvas and rebuild the runtime.
extension AppModel {
    /// Thread 0 is where Dirigo keeps everything on a `*` sheet — the thread of the *call* decides when it runs.
    var threadForNewBlocks: Int { selectedPage.hasPrefix("*") ? 0 : 1 }

    /// The macros the current page may call: every sheet except itself and the sheets that already call it.
    public var callableMacros: [String] { project?.callableSheets(from: selectedPage) ?? [] }

    /// Which interface blocks the current page still lacks. Empty on a main page.
    public var missingMacroInterfaces: [MacroInterface.Kind] {
        guard let project, selectedPage.hasPrefix("*") else { return [] }
        return MacroInterface.Kind.allCases.filter { project.macroInterface($0, onSheet: selectedPage) == nil }
    }

    private func freeSpot(near centre: CGPoint, in project: PCCProject) -> CGPoint {
        var spot = centre
        while project.modules.contains(where: { $0.page == selectedPage && abs($0.x - spot.x) < 24 && abs($0.y - spot.y) < 24 }) {
            spot.x += 28
            spot.y += 22
        }
        return spot
    }

    private func nextName(_ stem: String, in project: PCCProject) -> String {
        var number = 1
        while project.modules.contains(where: { $0.name == "\(stem)\(number)" }) { number += 1 }
        return "\(stem)\(number)"
    }

    /// Puts a call of `sheet` on the current page, with the pins its interface lists.
    @discardableResult
    public func addMacroCall(sheet: String, at point: CGPoint? = nil) -> Int? {
        guard var project, callableMacros.contains(sheet) else { return nil }
        let id = BlockFactory.nextId(in: project)
        let spot = freeSpot(near: point ?? viewportCentreInCanvas(), in: project)
        let order = (project.modules.filter { $0.page == selectedPage }.map(\.order).max() ?? 0) + 10
        let call = project.makeMacroCall(sheet: sheet, id: id,
                                         name: nextName(MacroInterface.name(ofSheet: sheet), in: project),
                                         x: spot.x, y: spot.y, order: order,
                                         threadId: threadForNewBlocks, page: selectedPage)
        project.modules.append(call)
        self.project = project
        selectedModuleId = id
        runtimeDidChangeStructure()
        return id
    }

    /// Puts the `Inputs` or `Outputs` block on the current macro page.
    @discardableResult
    public func addMacroInterface(_ kind: MacroInterface.Kind, at point: CGPoint? = nil) -> Int? {
        guard var project, missingMacroInterfaces.contains(kind) else { return nil }
        let id = BlockFactory.nextId(in: project)
        let spot = freeSpot(near: point ?? viewportCentreInCanvas(), in: project)
        let order = (project.modules.filter { $0.page == selectedPage }.map(\.order).max() ?? 0) + 10
        let module = project.makeMacroInterface(kind, onSheet: selectedPage, id: id,
                                                name: nextName(kind.attributeName, in: project),
                                                x: spot.x, y: spot.y, order: order)
        project.modules.append(module)
        self.project = project
        selectedModuleId = id
        runtimeDidChangeStructure()
        return id
    }

    /// Adds a pin to an interface block; every call of the macro grows the same pin.
    public func addInterfacePin(moduleId: Int) {
        guard var project, project.addInterfacePin(moduleId: moduleId) else { return }
        self.project = project
        runtimeDidChangeStructure()
    }

    public func renameInterfacePin(moduleId: Int, pin: Int, to name: String) {
        guard var project, project.renameInterfacePin(moduleId: moduleId, pin: pin, to: name) else { return }
        self.project = project
        runtimeDidChangeStructure()
    }

    public func removeInterfacePin(moduleId: Int, pin: Int) {
        guard var project, project.removeInterfacePin(moduleId: moduleId, pin: pin) else { return }
        self.project = project
        runtimeDidChangeStructure()
    }

    /// Renames a macro page; its calls follow. Returns false for a name that is empty or taken.
    @discardableResult
    public func renameMacroPage(_ caption: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = trimmed.hasPrefix("*") ? trimmed : "*" + trimmed
        guard var project, project.renameMacroSheet(from: caption, to: new) else { return false }
        self.project = project
        if selectedPage == caption { selectedPage = new }
        runtimeDidChangeStructure()
        return true
    }
}
