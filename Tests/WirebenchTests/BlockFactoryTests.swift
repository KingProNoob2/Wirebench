import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import WirebenchCore
@testable import WirebenchLibrary

/// Creating a block has to produce something the simulation understands *and* that the original
/// Dirigo will still open, so the pin layout matters as much as the placement.
@Suite("Creating blocks")
struct BlockFactoryTests {
    static let andGuid = UUID(uuidString: "058EE871-1370-46E7-AC3E-905CB632A211")!
    static let pulseGenGuid = UUID(uuidString: "74F92168-F67B-4364-8AC0-B735DAA400A3")!

    @Test("The pin catalog covers most of the recovered block types")
    func catalogCoverage() {
        #expect(PinTemplateCatalog.count >= 120)
        // Every template must be usable.
        for (_, template) in PinTemplateCatalog.byGuid {
            #expect(!template.inputs.isEmpty || !template.outputs.isEmpty)
        }
    }

    @Test("A configurable-input block gets <count> operands, not the placeholder row")
    func andPins() {
        let module = BlockFactory.makeModule(
            guid: Self.andGuid, id: 1, name: "And1", x: 0, y: 0,
            order: 10, threadId: 1, page: "main"
        )
        // The help lists En, X0, X1, X(N-1); the general row replaces the operands, so with N = 2
        // that is En, X0, X1 — which is what Dirigo itself writes.
        #expect(module.inPins.count == 3)
        #expect(module.outPins.count == 1)
        #expect(module.inputCount == 2)
        // Dirigo stores the literal from the help table, so the numeric form is expected; what
        // matters is that it reads back as enabled.
        #expect(module.inPins[0].value.asBool == true)    // En defaults to 1
        #expect(module.outPins[0].rights == 2)
    }

    @Test("Parameters and outputs come from the documented table")
    func pulseGenPins() {
        let module = BlockFactory.makeModule(
            guid: Self.pulseGenGuid, id: 1, name: "PulseGen1", x: 0, y: 0,
            order: 10, threadId: 1, page: "main"
        )
        #expect(module.inPins.count == 2)
        #expect(module.paramPins.count == 2)
        #expect(module.outPins.count == 2)
        #expect(module.inputCount == nil)
    }

    @Test("A type with no recovered layout still produces a usable block")
    func unknownTypeFallback() {
        let module = BlockFactory.makeModule(
            guid: UUID(), id: 1, name: "Mystery1", x: 0, y: 0,
            order: 10, threadId: 1, page: "main"
        )
        #expect(module.inPins.count == 1)
        #expect(module.outPins.count == 1)
    }

    @Test("Names, ids and execution order do not collide")
    func uniquePlacement() {
        var project = PCCProject(name: "t")
        project.modules = [
            PCCModule(id: 4, guid: Self.andGuid, name: "And", x: 0, y: 0, order: 30,
                      threadId: 1, page: "main"),
            PCCModule(id: 9, guid: Self.andGuid, name: "And1", x: 10, y: 0, order: 40,
                      threadId: 1, page: "main"),
        ]
        #expect(BlockFactory.nextId(in: project) == 10)
        #expect(BlockFactory.nextOrder(in: project, page: "main") == 50)
        #expect(BlockFactory.suggestedName(for: Self.andGuid, existing: project.modules) == "And2")
    }

    @Test("A brand-new project serialises to something Dirigo can open")
    func newProjectRoundTrips() throws {
        // What `createNewProject()` builds: one empty page, nothing else.
        let project = PCCProject(name: "Untitled", pages: [ProjectPage(caption: "main")], modules: [])
        let xml = PCCSerializer().serialize(project: project)

        // The sections Dirigo's reader expects must all be present, even when empty.
        for section in ["PCC_PROJECT", "PAGES", "PAGE", "MODULES", "CONNECTIONS",
                        "IN_CONNECTIONS", "PARAM_CONNECTIONS"] {
            #expect(xml.contains("<\(section)"), "missing \(section) in a new project")
        }
        #expect(xml.contains("PAGESIZE="))

        let reparsed = try PCCParser().parse(xmlString: xml)
        #expect(reparsed.pages.count == 1)
        #expect(reparsed.pages[0].caption == "main")
        #expect(reparsed.modules.isEmpty)
    }

    @Test("A created block is simulation-ready and survives a save")
    func createdBlockRoundTrips() throws {
        var project = PCCProject(name: "Round")
        project.pages = [ProjectPage(caption: "main")]
        let module = BlockFactory.makeModule(
            guid: Self.andGuid, id: 1, name: "And1", x: 120, y: 90,
            order: 10, threadId: 1, page: "main"
        )
        project.modules = [module]

        // The engine must be able to build it...
        let block = BlockRegistry.shared.create(for: module)
        #expect(!(block is UnresolvedBlock), "a real block type must not become a placeholder")

        // ...and the file must still be something Dirigo can read.
        let xml = PCCSerializer().serialize(project: project)
        #expect(xml.contains("NAME=\"And1\""))
        #expect(xml.contains("GUID=\"{058EE871-1370-46E7-AC3E-905CB632A211}\""))

        let reparsed = try PCCParser().parse(xmlString: xml)
        #expect(reparsed.modules.count == 1)
        #expect(reparsed.modules[0].inPins.count == 3)
        #expect(reparsed.modules[0].outPins.count == 1)
    }
}

@Suite("Value block")
struct ValueBlockTests {
    @Test("A display-only block resets without trapping on its empty output list")
    func resetWithNoOutputs() {
        let block = ValueDisplayBlock()
        #expect(block.outPins.isEmpty, "the help and real files give Value no outputs")
        block.reset()          // used to write outPins[0] unconditionally
        block.process(sample: SampleContext())
        #expect(block.formattedText == "0")
    }
}
