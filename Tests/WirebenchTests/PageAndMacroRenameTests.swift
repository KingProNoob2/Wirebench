import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// Renaming a page and renaming a macro.
///
/// A caption is a reference, not a label: every block, graphic and PLC configuration entry names its page by caption, and a
/// macro's sheet name is what each call site stores in `MACRO_NAME`. So these are reference surgery, and the thing to prove
/// is that the *saved file* (and therefore the legacy export, which writes the same document) carries the new name and
/// nothing is left pointing at the old one.
@Suite("Renaming pages and macros")
@MainActor
struct PageAndMacroRenameTests {
    /// `main` with a `Not` and a call of `*Adder`; `second` with a graphic and a configuration entry; `*Adder` with its
    /// interface and an `Add`; `*Outer`, which also calls `*Adder`, so a nested call site is renamed too.
    static func model() throws -> AppModel {
        var project = PCCProject(name: "rename")
        project.pages = ["main", "second", "*Adder", "*Outer"].map { ProjectPage(caption: $0) }
        project.modules = [
            PCCModule(id: 1, guid: NotBlock.guid, name: "Not1", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            PCCModule(id: 2, guid: NotBlock.guid, name: "Not2", x: 0, y: 200, order: 10, threadId: 1, page: "second",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            project.makeMacroInterface(.inputs, onSheet: "*Adder", id: 100, name: "Inputs1", x: 0, y: 0, order: 10),
            project.makeMacroInterface(.outputs, onSheet: "*Adder", id: 101, name: "Outputs1", x: 600, y: 0, order: 60),
            PCCModule(id: 102, guid: AddBlock.guid, name: "Add1", x: 200, y: 0, order: 30, threadId: 0, page: "*Adder",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(0))],
                      outPins: [Pin(id: 0, value: .int32(0))]),
            project.makeMacroInterface(.inputs, onSheet: "*Outer", id: 200, name: "Inputs1", x: 0, y: 0, order: 10),
            project.makeMacroInterface(.outputs, onSheet: "*Outer", id: 201, name: "Outputs1", x: 600, y: 0, order: 50),
        ]
        project.modules.append(project.makeMacroCall(sheet: "*Adder", id: 3, name: "Adder1", x: 300, y: 0, order: 20,
                                                     threadId: 1, page: "main"))
        project.modules.append(project.makeMacroCall(sheet: "*Adder", id: 4, name: "Adder2", x: 300, y: 100, order: 20,
                                                     threadId: 1, page: "main"))
        project.modules.append(project.makeMacroCall(sheet: "*Adder", id: 5, name: "Adder3", x: 200, y: 200, order: 30,
                                                     threadId: 0, page: "*Outer"))
        project.modules.append(project.makeMacroCall(sheet: "*Outer", id: 6, name: "Outer1", x: 500, y: 0, order: 30,
                                                     threadId: 1, page: "main"))
        project.graphics = [ProjectGraphic(type: 1, page: "second", text: "A label")]
        var entry = PLCConfiguration.newEntry(nil)
        entry.page = "second"
        project.plcConfiguration = [entry]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return model
    }

    @Test("Renaming a page carries its blocks, graphics and configuration entries")
    func renamesAPage() throws {
        let model = try Self.model()
        model.selectedPage = "second"
        #expect(model.renamePage("second", to: "detail"))

        let project = try #require(model.project)
        #expect(project.pages.map(\.caption).contains("detail"))
        #expect(!project.pages.map(\.caption).contains("second"))
        #expect(project.modules.filter { $0.id == 2 }.first?.page == "detail")
        #expect(project.modules.filter { $0.id == 1 }.first?.page == "main", "another page is not touched")
        #expect(project.graphics.allSatisfy { $0.page == "detail" })
        #expect(project.plcConfiguration.allSatisfy { $0.page == "detail" })
        #expect(model.selectedPage == "detail", "the page being shown follows the rename")
    }

    @Test("The saved file carries the new page name, and the export writes the same document")
    func pageNameReachesTheFile() throws {
        let model = try Self.model()
        #expect(model.renamePage("second", to: "detail"))
        let project = try #require(model.project)

        let text = PCCSerializer().serialize(project: project)
        #expect(text.contains("CAPTION=\"detail\""))
        #expect(text.contains("PAGE=\"detail\""))
        #expect(!text.contains("CAPTION=\"second\""))
        #expect(!text.contains("PAGE=\"second\""))

        // The legacy export is the same project, fitted to Dirigo's sheet: the names must travel with it.
        let exported = PCCSerializer().serialize(project: PaperSize.prepareForDirigo(project, extent: CardGeometry.dirigoExtent(for:)).project)
        #expect(exported.contains("CAPTION=\"detail\""))
        #expect(exported.contains("PAGE=\"detail\""))
        #expect(!exported.contains("second"))
    }

    @Test("A page rename refuses an empty, taken or macro-shaped name, and a page that is not there")
    func pageRenameRefusals() throws {
        let model = try Self.model()
        #expect(!model.renamePage("second", to: ""))
        #expect(!model.renamePage("second", to: "   "))
        #expect(!model.renamePage("second", to: "main"), "a name another page has")
        #expect(!model.renamePage("second", to: "*Adder"), "a normal page cannot become a macro sheet")
        #expect(!model.renamePage("missing", to: "anything"))
        // Renaming a page to its own name with different case is this page being renamed, not a collision.
        #expect(model.renamePage("second", to: "Second"))
        #expect(model.project?.pages.map(\.caption).contains("Second") == true)
    }

    @Test("Renaming a macro renames its sheet and every call, including calls inside another macro")
    func renamesAMacro() throws {
        let model = try Self.model()
        model.selectedPage = "*Adder"
        #expect(model.renamePage("*Adder", to: "Summer"))

        let project = try #require(model.project)
        #expect(project.pages.map(\.caption).contains("*Summer"))
        #expect(!project.pages.map(\.caption).contains("*Adder"))
        #expect(model.selectedPage == "*Summer")
        // The sheet's own blocks moved with it.
        #expect(project.modules.filter { $0.page == "*Summer" }.count == 3)
        // Every call — on main and the nested one inside `*Outer` — names the new macro.
        let calls = project.modules.filter { MacroCalls.target(of: $0) != nil }
        #expect(calls.count == 4, "three calls of Adder and one of Outer: \(calls.map(\.name))")
        #expect(calls.allSatisfy { MacroCalls.target(of: $0)?.lowercased() != "adder" }, "a call still names the old macro")
        #expect(calls.filter { MacroCalls.target(of: $0) == "Summer" }.count == 3)
        #expect(project.calls(ofSheet: "*Summer").count == 3)
    }

    @Test("The rename reaches the saved file and the export for a macro too")
    func macroNameReachesTheFile() throws {
        let model = try Self.model()
        #expect(model.renamePage("*Adder", to: "Summer"))
        let project = try #require(model.project)
        for text in [PCCSerializer().serialize(project: project),
                     PCCSerializer().serialize(project: PaperSize.prepareForDirigo(project, extent: CardGeometry.dirigoExtent(for:)).project)] {
            #expect(text.contains("CAPTION=\"*Summer\""))
            #expect(text.contains("MACRO_NAME=\"Summer\""))
            #expect(!text.contains("MACRO_NAME=\"Adder\""))
            #expect(!text.contains("CAPTION=\"*Adder\""))
        }
    }

    @Test("A macro rename is the only thing renameMacroPage will do")
    func macroRenameRefusesAPage() throws {
        let model = try Self.model()
        #expect(!model.renameMacroPage("second", to: "detail"))
        #expect(model.renameMacroPage("*Adder", to: "Summer"))
    }

    @Test("A rename is undoable like any other edit")
    func renameUndoes() throws {
        let model = try Self.model()
        #expect(model.renamePage("second", to: "detail"))
        #expect(model.project?.pages.map(\.caption).contains("detail") == true)

        model.undo()
        #expect(model.project?.pages.map(\.caption).contains("second") == true)
        #expect(model.project?.modules.filter { $0.id == 2 }.first?.page == "second")
    }
}
