import Testing
import Foundation
@testable import DirigoCore
import DirigoLibrary
@testable import DirigoApp

/// Pages (the "lists" in the sidebar). A page's caption is what every block on it references, so
/// creating and deleting pages is reference surgery, not just list editing.
@MainActor
@Suite("Pages")
struct PageTests {

    private func makeModel() throws -> AppModel {
        var project = PCCProject(name: "pages")
        project.pages = [ProjectPage(caption: "main"), ProjectPage(caption: "other")]
        project.modules = [
            PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .int32(0))]),
            PCCModule(id: 2, guid: NotBlock.guid, name: "Not1", x: 100, y: 0, order: 20,
                      threadId: 1, page: "other",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        project.inConnections = [Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        try model.loadProject(url: url)
        return model
    }

    @Test("A new page is added, selected, and given a name that cannot collide")
    func addsPages() throws {
        let model = try makeModel()

        let created = model.addPage(caption: "main")          // clashes with an existing page
        #expect(created == "main2", "a clashing caption must not merge two pages into one")
        #expect(model.selectedPage == "main2", "the new page is switched to")
        #expect(model.project?.pages.count == 3)

        let macro = model.addPage(caption: "Routine", isMacro: true)
        #expect(macro == "*Routine", "macro pages are stored with a leading star")

        let blank = model.addPage(caption: "   ")
        #expect(blank == "Page", "an empty name falls back rather than creating an unnamed page")
    }

    @Test("Deleting a page takes its blocks and their wires with it")
    func deletesPages() throws {
        let model = try makeModel()
        #expect(model.moduleCount(onPage: "other") == 1)

        #expect(model.deletePage(caption: "other"))

        #expect(model.project?.pages.count == 1)
        #expect(model.module(id: 2) == nil, "the block that lived on it is gone")
        #expect(model.module(id: 1) != nil, "blocks on other pages are untouched")
        #expect(model.project?.inConnections.isEmpty == true, "the wire feeding it went too")
        #expect(model.project?.danglingConnectionCount() == 0, "no cable may be left pointing at nothing")
        #expect(model.selectedPage == "main", "selection moves to a page that still exists")
        // The runtime is rebuilt, so the deleted block is no longer scheduled.
        #expect(model.executionOrder(forThread: 1) == [1])
    }

    @Test("The last page cannot be deleted")
    func keepsTheLastPage() throws {
        let model = try makeModel()
        #expect(model.deletePage(caption: "other"))
        #expect(model.deletePage(caption: "main") == false, "a project with no pages has nowhere to put a block")
        #expect(model.project?.pages.count == 1)
        #expect(model.deletePage(caption: "does-not-exist") == false)
    }

    @Test("Creating and deleting pages is undoable")
    func pageEditsAreUndoable() throws {
        let model = try makeModel()
        let before = model.history.undoCount

        model.addPage(caption: "extra")
        #expect(model.history.undoCount == before + 1, "adding a page is a document edit")
        model.undo()
        #expect(model.project?.pages.count == 2)

        model.deletePage(caption: "other")
        #expect(model.project?.pages.count == 1)
        model.undo()
        #expect(model.project?.pages.count == 2, "undo brings the page back")
        #expect(model.module(id: 2) != nil, "and the block that was on it")
    }
}
