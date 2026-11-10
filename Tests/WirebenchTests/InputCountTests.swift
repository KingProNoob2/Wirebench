import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

@Suite("Input count")
@MainActor
struct InputCountTests {
    @Test("Adding inputs to a logic block gives them runtime pins and survives a save")
    func addedInputsAreUsable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inputcount-\(UUID()).pcc")
        try PCCSerializer().serialize(project: BlockDeletionTests.project()).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        let id = 1   // an And block
        model.updateModuleInputCount(id: id, count: 5)
        #expect(model.getNode(id: id)?.block.inPins.count == 6, "En + five inputs in the engine")
        try model.saveProject(to: url)
        let reloaded = try PCCParser().parse(fileAt: url)
        #expect(reloaded.modules.first { $0.id == id }?.inputCount == 5)
    }
}
