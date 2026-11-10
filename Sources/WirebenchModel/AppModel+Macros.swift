import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import WirebenchCore
import WirebenchLibrary

/// Building macros in the editor: a `*` page, its `Inputs` / `Outputs` interface, and calls of it from other pages.
///
/// The rules live in `MacroInterface` / `PCCProject` (WirebenchCore), where they are testable without a view; these
/// methods only place things on the canvas and rebuild the runtime.
extension AppModel {
    /// Thread 0 is where Dirigo keeps everything on a `*` sheet — the thread of the *call* decides when it runs.
    package var threadForNewBlocks: Int { selectedPage.hasPrefix("*") ? 0 : 1 }

    /// The macros the current page may call: every sheet except itself and the sheets that already call it.
    public var callableMacros: [String] { project?.callableSheets(from: selectedPage) ?? [] }

    /// Which interface blocks the current page still lacks. Empty on a main page.
    public var missingMacroInterfaces: [MacroInterface.Kind] {
        guard let project, selectedPage.hasPrefix("*") else { return [] }
        return MacroInterface.Kind.allCases.filter { project.macroInterface($0, onSheet: selectedPage) == nil }
    }

    /// Applies an edit to the project; when it took, publishes it and rebuilds the runtime.
    @discardableResult
    private func edit(_ change: (inout PCCProject) -> Bool) -> Bool {
        guard var project, change(&project) else { return false }
        self.project = project
        runtimeDidChangeStructure()
        return true
    }

    /// Appends `make`'s module to the current page — at the middle of the view, nudged off any block already
    /// there — selects it and rebuilds the runtime.
    private func place(at point: CGPoint?, _ make: (PCCProject, _ id: Int, _ spot: CGPoint, _ order: Int) -> PCCModule) -> Int? {
        guard var project else { return nil }
        var spot = point ?? viewportCentreInCanvas()
        while project.modules.contains(where: { $0.page == selectedPage && abs($0.x - spot.x) < 24 && abs($0.y - spot.y) < 24 }) {
            spot.x += 28
            spot.y += 22
        }
        let id = BlockFactory.nextId(in: project)
        project.modules.append(make(project, id, spot, BlockFactory.nextOrder(in: project, page: selectedPage)))
        self.project = project
        selectedModuleId = id
        runtimeDidChangeStructure()
        return id
    }

    /// `stem1`, `stem2`, … — the first name no module has.
    private func nextName(_ stem: String, in project: PCCProject) -> String {
        var number = 1
        while project.modules.contains(where: { $0.name == "\(stem)\(number)" }) { number += 1 }
        return "\(stem)\(number)"
    }

    /// Puts a call of `sheet` on the current page, with the pins its interface lists.
    @discardableResult
    public func addMacroCall(sheet: String, at point: CGPoint? = nil) -> Int? {
        guard callableMacros.contains(sheet) else { return nil }
        let thread = threadForNewBlocks, page = selectedPage
        return place(at: point) { project, id, spot, order in
            project.makeMacroCall(sheet: sheet, id: id, name: nextName(MacroInterface.name(ofSheet: sheet), in: project),
                                  x: spot.x, y: spot.y, order: order, threadId: thread, page: page)
        }
    }

    /// Puts the `Inputs` or `Outputs` block on the current macro page.
    @discardableResult
    public func addMacroInterface(_ kind: MacroInterface.Kind, at point: CGPoint? = nil) -> Int? {
        guard missingMacroInterfaces.contains(kind) else { return nil }
        let page = selectedPage
        return place(at: point) { project, id, spot, order in
            project.makeMacroInterface(kind, onSheet: page, id: id, name: nextName(kind.attributeName, in: project),
                                       x: spot.x, y: spot.y, order: order)
        }
    }

    /// Adds a pin to an interface block; every call of the macro grows the same pin.
    public func addInterfacePin(moduleId: Int) {
        edit { $0.addInterfacePin(moduleId: moduleId) }
    }

    public func renameInterfacePin(moduleId: Int, pin: Int, to name: String) {
        edit { $0.renameInterfacePin(moduleId: moduleId, pin: pin, to: name) }
    }

    public func removeInterfacePin(moduleId: Int, pin: Int) {
        edit { $0.removeInterfacePin(moduleId: moduleId, pin: pin) }
    }

    /// Renames a page: a normal one, or a macro page, whose calls follow the new name.
    ///
    /// A macro page's name is its `*` caption, and every call site names it with `MACRO_NAME`, so those are renamed with it
    /// (`PCCProject.renameMacroSheet`). A normal page is renamed with the blocks, graphics and PLC configuration entries that
    /// sit on it (`PCCProject.renamePage`). Either way the project keeps its own references, so what is saved and what the
    /// legacy export writes carry the new name. Returns false for a name that is empty, already taken, or would turn a page
    /// into a macro sheet (or the reverse).
    @discardableResult
    public func renamePage(_ caption: String, to name: String) -> Bool {
        guard let project, project.pages.contains(where: { $0.caption == caption }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let new: String
        if caption.hasPrefix("*") {
            new = trimmed.hasPrefix("*") ? trimmed : "*" + trimmed
            guard new.count > 1, edit({ $0.renameMacroSheet(from: caption, to: new) }) else { return false }
        } else {
            new = trimmed
            guard !trimmed.hasPrefix("*"), edit({ $0.renamePage(from: caption, to: trimmed) }) else { return false }
        }
        if selectedPage == caption { selectedPage = new }
        return true
    }

    /// Renames a macro page; its calls follow. Kept for the callers that only ever rename macros (the bridge's older
    /// `renameMacro`, the sidebar's menu) — it is `renamePage` that refuses anything else.
    @discardableResult
    public func renameMacroPage(_ caption: String, to name: String) -> Bool {
        guard caption.hasPrefix("*") else { return false }
        return renamePage(caption, to: name)
    }
}
