import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
import WirebenchSource
@testable import WirebenchModel

/// A block may feed its own input. A counter's output into its own reset is how a self-resetting counter is built, and
/// the engine reads the producer's value as it stands — feedback, not a cycle to refuse.
@Suite("Self-wiring")
struct SelfWiringTests {
    private func project() -> (PCCProject, Int) {
        var project = PCCProject(name: "self", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        let guid = BlockTypeCatalog.info(forBlockName: "AdvCounter")!.guid
        let counter = BlockFactory.makeModule(guid: guid, id: 1, name: "AdvCounter1",
                                              x: 0, y: 0, order: 10, threadId: 1, page: "main")
        project.modules = [counter]
        return (project, counter.id)
    }

    @Test("A project accepts an output wired to its own input, and the wire survives a save")
    func projectAcceptsSelfWire() throws {
        var (project, counter) = project()
        // Y (output 0) into Rst (input 2).
        #expect(project.connect(outModuleId: counter, outPinId: 0, toModuleId: counter, inPinId: 2) == nil)
        #expect(project.inConnections.count == 1)

        let xml = PCCSerializer().serialize(project: project)
        let read = try PCCParser().parse(xmlString: xml)
        #expect(read.inConnections.count == 1)
        #expect(read.inConnections.first?.outModuleId == counter)
        #expect(read.inConnections.first?.inPinId == 2)

        // The core takes the step without a cycle guard or a crash.
        let core = CxxSimulationCore(project: read, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
    }

    @Test("The editor's connectPins allows it, and Undo takes it back")
    @MainActor
    func editorAcceptsSelfWire() throws {
        let (project, counter) = project()
        let model = AppModel()
        model.project = project
        model.selectedPage = "main"
        let wired = model.connectPins(from: PinReference(moduleId: counter, side: .output, index: 0),
                                      to: PinReference(moduleId: counter, side: .input, index: 2))
        #expect(wired)
        #expect(model.project?.inConnections.count == 1)
        #expect(model.canUndo)
        model.undo()
        #expect(model.project?.inConnections.isEmpty == true)
    }

    @Test("A self-wired block is recovered and recompiled with its wire")
    func decompileKeepsSelfWire() throws {
        var (project, counter) = project()
        #expect(project.connect(outModuleId: counter, outPinId: 0, toModuleId: counter, inPinId: 2) == nil)
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains(":= AdvCounter1.Y"))
        let again = try SourceCompiler().compile(source)
        let wire = try #require(again.project.inConnections.first)
        #expect(wire.outModuleId == wire.inModuleId)
        #expect(wire.inPinId == 2)
    }

    @Test("Copying a self-wired block keeps the wire on the copy")
    @MainActor
    func copyPasteKeepsSelfWire() throws {
        let (project, counter) = project()
        var wired = project
        #expect(wired.connect(outModuleId: counter, outPinId: 0, toModuleId: counter, inPinId: 2) == nil)
        let model = AppModel()
        model.project = wired
        model.selectedModuleIds = [counter]
        model.selectedModuleId = counter
        #expect(model.copySelection())
        let pasted = model.paste()
        let copy = try #require(pasted.first)
        let wire = try #require(model.project?.inConnections.first { $0.inModuleId == copy })
        #expect(wire.outModuleId == copy)
        #expect(wire.inModuleId == copy)
        #expect(wire.inPinId == 2)
    }

    @Test("A self-wire routes as a cable rather than failing to draw")
    func selfWireRoutes() throws {
        let (project, counter) = project()
        var wired = project
        #expect(wired.connect(outModuleId: counter, outPinId: 0, toModuleId: counter, inPinId: 2) == nil)
        let points = WireRouter.route(from: CGPoint(x: 100, y: 40), to: CGPoint(x: 20, y: 90))
        #expect(points.count >= 2)
    }
}
