import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchEngine
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

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

    /// A block whose shape changes while the project is open (here `Int2Bits` going from eight outputs to
    /// four) must run in its new shape. The Swift engine swapped a new block object in; the core is rebuilt
    /// from the document instead, so this checks the result rather than the mechanism.
    @Test("A block whose output count changes runs in its new shape")
    @MainActor
    func reshapedBlockRuns() throws {
        var project = PCCProject(name: "swap")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [PCCModule(id: 1, guid: Int2BitsBlock.guid, name: "Int2Bits1", x: 0, y: 0,
                                     order: 10, threadId: 1, page: "main",
                                     inPins: [Pin(id: 0, value: .int32(0))],
                                     outPins: (0..<8).map { Pin(id: $0, value: .bool(false)) })]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reshape-\(UUID().uuidString).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        model.updateModuleOutputCount(id: 1, count: 4)
        model.setModuleInput(moduleId: 1, pinIndex: 0, value: .int32(5))
        #expect(model.getNode(id: 1)?.block.outPins.map(\.asBool) == [true, false, true, false])
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

    @Test("deleteModule(id:) drops any wire and selection state attached to that block")
    @MainActor
    func deleteModuleCleansSelectionAndWire() {
        let model = AppModel()
        var project = PCCProject(name: "del-clean")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [1, 2, 3].map { id in
            PCCModule(id: id, guid: BlockDeletionTests.andGuid, name: "And\(id)", x: Double(id) * 100, y: 0, order: id * 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))])
        }
        project.inConnections = [Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0)]
        model.project = project
        model.selectedWire = RoutedWire.Key(outModule: 1, outPin: 0, inModule: 2, inPin: 0)
        model.selectedModuleIds = [1, 3]
        model.selectedModuleId = 1
        model.configuringModuleId = 2
        model.renamingModuleId = 2

        #expect(model.deleteModule(id: 2))
        #expect(model.selectedWire == nil)
        #expect(model.configuringModuleId == nil)
        #expect(model.renamingModuleId == nil)
        #expect(model.selectedModuleIds == [1, 3])

        #expect(model.deleteModule(id: 3))
        #expect(model.selectedModuleIds == [1], "removing a non-primary selected block drops only its id")
    }

    @Test("Deleting selected annotations stays on the shown page, clears selection, and undoes as one edit")
    @MainActor
    func deleteSelectedAnnotationsStaysOnPageAndSingleUndo() throws {
        let model = AppModel()
        model.createNewProject()
        _ = model.addPage(caption: "other")
        model.selectedPage = "main"
        let mainA = try #require(model.addShape(.rectangle, at: CGPoint(x: 100, y: 100)))
        let mainB = try #require(model.addShape(.ellipse, at: CGPoint(x: 250, y: 100)))
        model.selectedPage = "other"
        let onOther = try #require(model.addShape(.rectangle, at: CGPoint(x: 100, y: 100)))

        model.adoptCompiledProject(try #require(model.project))
        model.selectedPage = "main"
        model.selectedAnnotationIndex = mainA
        model.selectedAnnotationIndices = [mainA, mainB, onOther]
        model.deleteSelectedAnnotation()

        #expect(model.project?.graphics.count == 1)
        #expect(model.project?.graphics.first?.page == "other")
        #expect(model.selectedAnnotationIndex == nil)
        #expect(model.selectedAnnotationIndices.isEmpty)

        model.undo()
        #expect(model.project?.graphics.count == 3, "deleting a multi-selection undoes as one step")
    }

    @Test("Deleting a page clears graphic selection and removes deleted module ids from multi-selection")
    @MainActor
    func deletePageCleansGraphicAndModuleSelection() throws {
        let model = AppModel()
        var project = PCCProject(name: "page-clean")
        project.pages = [ProjectPage(caption: "main"), ProjectPage(caption: "other")]
        project.modules = [
            PCCModule(id: 1, guid: BlockDeletionTests.andGuid, name: "And1", x: 0, y: 0, order: 10, threadId: 1, page: "main"),
            PCCModule(id: 2, guid: BlockDeletionTests.andGuid, name: "And2", x: 0, y: 0, order: 20, threadId: 1, page: "other"),
        ]
        model.project = project
        model.selectedPage = "other"
        let graphicOnOther = try #require(model.addShape(.rectangle, at: CGPoint(x: 100, y: 100)))
        model.selectedAnnotationIndex = graphicOnOther
        model.selectedModuleIds = [1, 2]
        model.selectedModuleId = 1
        model.configuringModuleId = 2
        model.renamingModuleId = 2

        #expect(model.deletePage(caption: "other"))
        #expect(model.selectedAnnotationIndex == nil)
        #expect(model.selectedAnnotationIndices.isEmpty)
        #expect(model.selectedModuleIds == [1])
        #expect(model.configuringModuleId == nil)
        #expect(model.renamingModuleId == nil)
    }

    @Test("BlockConfig.apply preserves omitted fields during partial updates")
    @MainActor
    func partialBlockConfigPreservesOmittedFields() {
        let model = AppModel()
        var project = PCCProject(name: "partial-cfg")
        project.pages = [ProjectPage(caption: "main")]
        var boolVar = BlockFactory.makeModule(guid: BoolVarBlock.guid, id: 1, name: "BV1",
                                             x: 0, y: 0, order: 10, threadId: 1, page: "main")
        boolVar.outPins = [Pin(id: 0, value: .bool(true))]
        let pulse = BlockFactory.makeModule(guid: PulseGenBlock.guid, id: 2, name: "PG1",
                                            x: 100, y: 0, order: 20, threadId: 1, page: "main")
        var dt = BlockFactory.makeModule(guid: DateTimeBlock.guid, id: 3, name: "DT1",
                                        x: 200, y: 0, order: 30, threadId: 1, page: "main")
        dt.rawAttributes["SHOW_OFFSET"] = "True"
        dt.rawAttributes["SHOW_SOD"] = "True"
        var di = BlockFactory.makeModule(guid: EightDIBlock.guid, id: 4, name: "DI1",
                                        x: 300, y: 0, order: 40, threadId: 1, page: "main")
        di.rawAttributes["PIN_MASK"] = "$000F"
        di.rawAttributes["PIN_ALL_VISIBLE"] = "True"
        var sw = PCCModule(id: 5, guid: ConstructContainers.switchGuid, name: "Sw1", x: 400, y: 0, order: 50,
                           threadId: 1, page: "main", inPins: [Pin(id: 0, value: .int32(0))])
        sw.rawAttributes["CONTAINER"] = "1"
        sw.rawAttributes["CASES"] = "a:1|b:2"
        sw.rawAttributes["DEFAULT"] = "1"
        project.modules = [boolVar, pulse, dt, di, sw]
        model.project = project
        model.runtimeDidChangeStructure()
        model.setModuleOutput(moduleId: 1, pinIndex: 0, value: .bool(true))

        BlockConfig.apply(["mode": "1"], to: 1, in: model)
        #expect(model.getNode(id: 1)?.block.outPins.first?.asBool == true)

        BlockConfig.apply(["tOff": "42"], to: 2, in: model)
        BlockConfig.apply(["tOn": "7"], to: 2, in: model)
        #expect(model.module(id: 2)?.paramPins[1].value.asInt == 42)
        #expect(model.module(id: 2)?.paramPins[0].value.asInt == 7)

        BlockConfig.apply(["offset": "0"], to: 3, in: model)
        #expect(model.module(id: 3)?.rawAttributes["SHOW_OFFSET"] == "False")
        #expect(model.module(id: 3)?.rawAttributes["SHOW_SOD"] == "True")

        BlockConfig.apply(["showWord": "0"], to: 4, in: model)
        #expect(model.module(id: 4)?.rawAttributes["PIN_MASK"] == "$000F")
        #expect(model.module(id: 4)?.rawAttributes["PIN_ALL_VISIBLE"] == nil)

        BlockConfig.apply(["default": "0"], to: 5, in: model)
        #expect(ConstructContainers.cases(of: model.module(id: 5)!).count == 2)
        #expect(model.module(id: 5)?.rawAttributes["DEFAULT"] == "0")
    }

    @Test("Variable, pulse, and counter setters clamp out-of-Int32 values instead of wrapping or trapping")
    @MainActor
    func numericSettersClampInt32() {
        let model = AppModel()
        var project = PCCProject(name: "clamp")
        project.pages = [ProjectPage(caption: "main")]
        let intVar = BlockFactory.makeModule(guid: IntVarBlock.guid, id: 1, name: "IV1",
                                             x: 0, y: 0, order: 10, threadId: 1, page: "main")
        let pulse = BlockFactory.makeModule(guid: PulseGenBlock.guid, id: 2, name: "PG1",
                                            x: 100, y: 0, order: 20, threadId: 1, page: "main")
        let counter = BlockFactory.makeModule(guid: CounterBlock.guid, id: 3, name: "C1",
                                              x: 200, y: 0, order: 30, threadId: 1, page: "main")
        project.modules = [intVar, pulse, counter]
        model.project = project
        model.runtimeDidChangeStructure()

        model.setVariableValue(moduleId: 1, value: Int(Int32.max) + 100)
        #expect(model.getNode(id: 1)?.block.outPins.first?.asInt32 == Int32.max)

        model.updatePulseGenTiming(id: 2, tOn: Int(Int32.max) + 5, tOff: Int(Int32.min) - 5)
        #expect(model.module(id: 2)?.paramPins[0].value.asInt32 == Int32.max)
        #expect(model.module(id: 2)?.paramPins[1].value.asInt32 == Int32.min)

        model.updateCounterStep(id: 3, step: Int(Int32.max) + 1)
        #expect(model.module(id: 3)?.paramPins[0].value.asInt32 == Int32.max)
    }

    @Test("Maraflow ARGB color conversion handles high-bit alpha values without trapping")
    @MainActor
    func maraflowColorHandlesAlphaHighBit() throws {
        var project = PCCProject(name: "mfl")
        project.pages = [ProjectPage(caption: "main")]
        let extras = MaraflowExtras(properties: [
            "project.pageCount": "1",
            "page.0.graphicCount": "1",
            "page.0.graphic.0.kind": "RECTANGLE",
            "page.0.graphic.0.gridX": "0",
            "page.0.graphic.0.gridY": "0",
            "page.0.graphic.0.gridW": "10",
            "page.0.graphic.0.gridH": "10",
            "page.0.graphic.0.strokeRgb": "\(0xFF112233)",
            "page.0.graphic.0.fillRgb": "\(0x80445566)",
        ])
        project.maraflow = extras
        let model = AppModel()
        model.project = project
        let snap = SceneSnapshot.maraflowGraphics(of: model, page: "main")
        try #require(snap.count == 1)
        #expect(snap[0].stroke == "#112233")
        #expect(snap[0].fill == "#445566")
    }
}
