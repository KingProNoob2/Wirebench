import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoLibrary
@testable import DirigoEngine
@testable import DirigoApp

@Suite("Deleting blocks")
struct BlockDeletionTests {
    static let andGuid = UUID(uuidString: "058EE871-1370-46E7-AC3E-905CB632A211")!

    /// Three blocks, wired 1 -> 2 -> 3, plus a parameter connection into 2.
    static func project() -> PCCProject {
        var p = PCCProject(name: "del")
        p.pages = [ProjectPage(caption: "main")]
        p.modules = [1, 2, 3].map { id in
            PCCModule(id: id, guid: andGuid, name: "And\(id)", x: Double(id) * 200, y: 0,
                      order: id * 10, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))],
                      outPins: [Pin(id: 0, value: .bool(false))])
        }
        p.inConnections = [
            Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0),
            Connection(inModuleId: 3, inPinId: 0, outModuleId: 2, outPinId: 0),
        ]
        p.paramConnections = [
            Connection(inModuleId: 2, inPinId: 0, outModuleId: 3, outPinId: 0, isParam: true),
        ]
        return p
    }

    @Test("Deleting a block takes its cables with it, in and out")
    func deletesBlockAndItsCables() {
        var project = Self.project()
        #expect(project.danglingConnectionCount() == 0)

        let removed = project.deleteModule(id: 2)
        // Both in-connections and the param connection referred to block 2.
        #expect(removed == 3)
        #expect(project.modules.map(\.id) == [1, 3])
        #expect(project.inConnections.isEmpty)
        #expect(project.paramConnections.isEmpty)
        // Nothing left pointing at the block that is gone.
        #expect(project.danglingConnectionCount() == 0)
    }

    @Test("Cables that do not touch the block are kept")
    func unrelatedCablesSurvive() {
        var project = Self.project()
        project.deleteModule(id: 3)
        // 1 -> 2 is untouched; both cables involving 3 are gone.
        #expect(project.inConnections.count == 1)
        #expect(project.inConnections[0].outModuleId == 1)
        #expect(project.paramConnections.isEmpty)
        #expect(project.danglingConnectionCount() == 0)
    }

    @Test("Deleting something that is not there changes nothing")
    func deletingMissingBlockIsANoOp() {
        var project = Self.project()
        let before = project
        #expect(project.deleteModule(id: 99) == nil)
        #expect(project == before)
    }

    @Test("A document with a deleted block is still one Dirigo can read")
    func serialisesAfterDeletion() throws {
        var project = Self.project()
        project.deleteModule(id: 2)

        let xml = PCCSerializer().serialize(project: project)
        #expect(!xml.contains("NAME=\"And2\""))

        let reparsed = try PCCParser().parse(xmlString: xml)
        #expect(reparsed.modules.count == 2)
        // The critical property: no connection names a module that is not in the file.
        #expect(reparsed.danglingConnectionCount() == 0)
    }
}

/// Regressions found in a review of the whole project.
@Suite("Review fixes")
struct ReviewFixTests {
    @Test("A float that does not fit an integer reads as a clamped integer instead of trapping")
    func floatToIntSaturates() {
        #expect(PinValue.float(.nan).asInt32 == 0)
        #expect(PinValue.float(.infinity).asInt32 == .max)
        #expect(PinValue.float(-.infinity).asInt32 == .min)
        #expect(PinValue.float(5e9).asInt32 == .max)
        #expect(PinValue.float(-5e9).asInt == Int(Int32.min))
        #expect(PinValue.float(-2.7).asInt32 == -2)
    }

    @Test("A block swapped into a running engine is the one a step runs")
    func swappedBlockRuns() {
        var project = PCCProject(name: "swap")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [PCCModule(id: 1, guid: Int2BitsBlock.guid, name: "Int2Bits1", x: 0, y: 0,
                                     order: 10, threadId: 1, page: "main",
                                     inPins: [Pin(id: 0, value: .int32(0))],
                                     outPins: (0..<8).map { Pin(id: $0, value: .bool(false)) })]
        let engine = SimulationEngine(project: project)
        let replacement = Int2BitsBlock(bitCount: 4)
        replacement.inPins[0] = .int32(5)
        engine.updateBlock(for: 1, newBlock: replacement)
        engine.step()
        #expect(replacement.outPins.map(\.asBool) == [true, false, true, false])
    }

    @Test("Deleting the selection leaves blocks on other pages alone")
    @MainActor
    func deleteSelectionStaysOnPage() {
        let model = AppModel()
        var project = PCCProject(name: "pages")
        project.pages = [ProjectPage(caption: "main"), ProjectPage(caption: "other")]
        project.modules = [1, 2].map { id in
            PCCModule(id: id, guid: BlockDeletionTests.andGuid, name: "And\(id)", x: 0, y: 0, order: id * 10,
                      threadId: 1, page: id == 1 ? "main" : "other")
        }
        model.project = project
        model.selectedPage = "main"
        model.selectedModuleIds = [1, 2]
        model.selectedModuleId = 1
        model.deleteSelectedModule()
        #expect(model.project?.modules.map(\.id) == [2])

        model.selectedModuleId = 2   // selected on "other", but "main" is shown
        model.deleteSelectedModule()
        #expect(model.project?.modules.map(\.id) == [2])
    }
}
