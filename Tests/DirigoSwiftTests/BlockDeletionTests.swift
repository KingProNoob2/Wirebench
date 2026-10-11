import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoLibrary

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
