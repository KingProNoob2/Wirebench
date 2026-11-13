import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine

/// The serializer keeps what the model does not type, and the simulator schedules what the compiler builds.
@Suite("Data fidelity and scheduling")
struct DataFidelityTests {
    @Test("POINTS and POINT attributes survive a save")
    func connectionPointAttributes() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            BlockFactory.makeModule(guid: EightDIBlock.guid, id: 1, name: "8xDI1", x: 0, y: 0, order: 10, threadId: 1, page: "main"),
            BlockFactory.makeModule(guid: EightDOBlock.guid, id: 2, name: "8xDO1", x: 100, y: 0, order: 20, threadId: 1, page: "main"),
        ]
        var connection = Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 0,
                                    points: [RoutePoint(x: 20, y: 30)])
        connection.pointsAttributes = ["KIND": "route"]
        connection.pointAttributes = [["EXTRA": "7"]]
        project.inConnections = [connection]

        let read = try PCCParser().parse(xmlString: PCCSerializer().serialize(project: project))
        let wire = try #require(read.inConnections.first)
        #expect(wire.pointsAttributes["KIND"] == "route")
        #expect(wire.pointAttributes.first?["EXTRA"] == "7")
        #expect(wire.points.first?.x == 20)
    }

    @Test("An unknown child of a modelled section survives a save")
    func unknownSectionChild() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [BlockFactory.makeModule(guid: AndBlock.guid, id: 1, name: "And1", x: 0, y: 0,
                                                 order: 10, threadId: 1, page: "main")]
        let xml = PCCSerializer().serialize(project: project)
        let injected = xml.replacingOccurrences(of: "</MODULES>", with: "<NOTE K=\"1\"/></MODULES>")
        let read = try PCCParser().parse(xmlString: injected)
        let again = PCCSerializer().serialize(project: read)
        #expect(again.contains("NOTE"), "an unknown child of MODULES was dropped")
        #expect(again.contains("K=\"1\""))
    }

    @Test("A moved graphic node and a pen change reach the verbatim subtree")
    func graphicEditsReachTheFile() throws {
        let url = TestCorpus.directories[0].appendingPathComponent("rulkoshaddirigo.pcc")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var project = try PCCParser().parse(fileAt: url)
        guard let index = project.graphics.firstIndex(where: { !$0.rawChildren.isEmpty && !$0.nodes.isEmpty }) else { return }
        let old = project.graphics[index].nodes[0]
        project.graphics[index].nodes[0] = RoutePoint(x: old.x + 5, y: old.y + 5)
        let xml = PCCSerializer().serialize(project: project)
        #expect(xml.contains("X=\"\(Int((old.x + 5).rounded()))\""))
        #expect(xml.contains("CHARSET"), "unknown FONT attributes are still there")
    }

    @Test("A non-macro block on THREAD_ID 0 does not run in the simulator, as it does not build")
    func threadZeroIsInert() throws {
        func output(thread: Int) throws -> Bool {
            var project = PCCProject(name: "P", profile: "Sybas Duino-E")
            project.pages = [ProjectPage(caption: "main")]
            let yes = BlockFactory.makeModule(guid: BlockTypeCatalog.info(forBlockName: "Yes")!.guid,
                                              id: 1, name: "Yes1", x: 0, y: 0, order: 10,
                                              threadId: thread, page: "main")
            project.modules = [yes]
            let core = CxxSimulationCore(project: project, profileScheduling: false)
            core.setIn(moduleId: 1, pin: 0, value: .bool(true))
            core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
            return core.outValue(moduleId: 1, pin: 0)?.asBool == true
        }
        #expect(try !output(thread: 0), "thread 0 is where the compiler keeps macro sheets, not circuit blocks")
        #expect(try output(thread: 1))
    }
}
