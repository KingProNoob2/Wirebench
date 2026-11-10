import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

@Suite("Copy and paste")
@MainActor
struct ClipboardTests {
    static func model() throws -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID()).pcc")
        try PCCSerializer().serialize(project: BlockDeletionTests.project()).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return model
    }

    @Test("Pasting copies blocks with their inner wires, new ids and names, and selects them")
    func pastesCopies() throws {
        let model = try Self.model()
        model.selectedModuleIds = [1, 2]
        model.selectedModuleId = 1
        #expect(model.copySelection())
        let ids = model.paste()
        #expect(ids.count == 2)
        let project = try #require(model.project)
        #expect(project.modules.count == 5)
        #expect(Set(project.modules.map(\.id)).count == 5, "ids stay unique")
        #expect(Set(project.modules.map(\.name)).count == 5, "names stay unique")
        #expect(project.inConnections.contains { ids.contains($0.inModuleId) && ids.contains($0.outModuleId) },
                "the wire between the copies came along")
        #expect(!project.inConnections.contains { ids.contains($0.inModuleId) != ids.contains($0.outModuleId) },
                "nothing is wired between a copy and an original")
        #expect(model.selectedModuleIds == Set(ids))
        #expect(model.hasSignificantChanges)
        model.undo()
        #expect(model.project?.modules.count == 3, "one undo takes the paste back")
    }

    @Test("A second paste lands further along, and nothing happens with an empty clipboard")
    func repeatsAndEmpty() throws {
        let model = try Self.model()
        #expect(model.paste().isEmpty)
        model.selectedModuleId = 3
        model.copySelection()
        let first = try #require(model.paste().first)
        let second = try #require(model.paste().first)
        let a = try #require(model.project?.modules.first { $0.id == first })
        let b = try #require(model.project?.modules.first { $0.id == second })
        #expect(b.x > a.x && b.y > a.y)
    }

    @Test("Cut copies, then removes")
    func cuts() throws {
        let model = try Self.model()
        model.selectedModuleId = 2
        #expect(model.cutSelection())
        #expect(model.project?.modules.count == 2)
        #expect(model.paste().count == 1)
        #expect(model.project?.modules.count == 3)
    }
}
