import Testing
import Foundation
import DirigoCore
import DirigoLibrary
@testable import DirigoApp

/// The sidebar search finds *blocks* and highlights them on the sheet. It must not filter anything
/// out — the point is to spot matches in place — and it has to be honest about hits on pages that
/// are not on screen, since those cannot be highlighted.
@MainActor
@Suite("Block search")
struct BlockSearchTests {

    private func makeModel() throws -> AppModel {
        var project = PCCProject(name: "search")
        project.pages = [ProjectPage(caption: "main"), ProjectPage(caption: "other")]
        project.modules = [
            PCCModule(id: 1, guid: SegmentBlock.guid, name: "Segment1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: []),
            PCCModule(id: 2, guid: BoolVarBlock.guid, name: "BoolVar1", x: 200, y: 0, order: 20,
                      threadId: 1, page: "main", inPins: [], outPins: [Pin(id: 0, value: .bool(false))]),
            PCCModule(id: 3, guid: SegmentBlock.guid, name: "Segment2", x: 0, y: 0, order: 30,
                      threadId: 1, page: "other",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: []),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        try model.loadProject(url: url)
        return model
    }

    @Test("An empty query highlights nothing")
    func emptyQueryMatchesNothing() throws {
        let model = try makeModel()
        #expect(model.highlightedModuleIds.isEmpty)
        #expect(model.blockSearchMatchCount == 0)
        #expect(model.moduleMatchesSearch(model.module(id: 1)!) == false)
    }

    @Test("Searching a block type names every instance of it")
    func matchesByBlockType() throws {
        let model = try makeModel()
        model.blockSearchText = "segment"

        #expect(model.highlightedModuleIds == [1], "only the one on the visible page can be highlighted")
        #expect(model.blockSearchMatchCount == 2, "but the project has two of them")

        model.selectedPage = "other"
        #expect(model.highlightedModuleIds == [3], "the highlight follows the visible page")
    }

    @Test("Searching matches an instance name, not just the type")
    func matchesByInstanceName() throws {
        let model = try makeModel()
        model.blockSearchText = "BoolVar1"
        #expect(model.highlightedModuleIds == [2])
        #expect(model.blockSearchMatchCount == 1)
    }

    @Test("Searching also finds the original Delphi class and the category")
    func matchesByClassAndCategory() throws {
        let model = try makeModel()
        let info = BlockTypeCatalog.byGuid[SegmentBlock.guid]!
        #expect(!info.delphiClass.isEmpty)

        model.blockSearchText = info.delphiClass
        #expect(model.highlightedModuleIds == [1], "the Delphi class is a useful way to find a type")

        model.blockSearchText = info.category
        #expect(model.blockSearchMatchCount >= 1, "category “\(info.category)” should find its blocks")
    }

    @Test("The query is trimmed and case-insensitive")
    func queryIsForgiving() throws {
        let model = try makeModel()
        model.blockSearchText = "   SeGmEnT  "
        #expect(model.highlightedModuleIds == [1])
    }
}
