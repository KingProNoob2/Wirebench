import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel
@testable import WirebenchCore
@testable import WirebenchLibrary

/// Building a macro in the editor — the way a person does, not by writing the file: a `*` page, its Inputs and
/// Outputs, a call from a main page.
@Suite("Macros in the editor")
struct MacroEditingTests {
    @MainActor
    func inverter() throws -> (model: AppModel, call: Int) {
        let model = AppModel()
        model.createNewProject()
        let sheet = try #require(model.addPage(caption: "inv", isMacro: true))
        #expect(sheet == "*inv")
        let inputs = try #require(model.addMacroInterface(.inputs))
        let outputs = try #require(model.addMacroInterface(.outputs))
        let not = try #require(model.addBlock(guid: NotBlock.guid))
        #expect(model.module(id: not)?.threadId == 0, "a block on a macro sheet belongs to thread 0, as Dirigo writes it")
        #expect(model.connectPins(from: .init(moduleId: inputs, side: .output, index: 0), to: .init(moduleId: not, side: .input, index: 1)))
        #expect(model.connectPins(from: .init(moduleId: not, side: .output, index: 0), to: .init(moduleId: outputs, side: .input, index: 0)))
        model.selectedPage = try #require(model.project?.pages.first { !$0.caption.hasPrefix("*") }?.caption)
        let call = try #require(model.addMacroCall(sheet: "*inv"))
        return (model, call)
    }

    @Test("A call made in the editor has the macro's name and the interface's pins")
    @MainActor func callShape() throws {
        let (model, call) = try inverter()
        let module = try #require(model.module(id: call))
        #expect(MacroCalls.target(of: module) == "inv")
        #expect(module.inPins.map(\.name) == ["A"])
        #expect(module.outPins.map(\.name) == ["Out1"])
        #expect(module.threadId == 1)
    }

    @Test("Two calls of one macro run independently")
    @MainActor func callsRun() throws {
        let (model, first) = try inverter()
        let second = try #require(model.addMacroCall(sheet: "*inv"))
        let a = try #require(model.addBlock(guid: BoolVarBlock.guid))
        let b = try #require(model.addBlock(guid: BoolVarBlock.guid))
        #expect(model.connectPins(from: .init(moduleId: a, side: .output, index: 0), to: .init(moduleId: first, side: .input, index: 0)))
        #expect(model.connectPins(from: .init(moduleId: b, side: .output, index: 0), to: .init(moduleId: second, side: .input, index: 0)))
        model.setModuleOutput(moduleId: a, pinIndex: 0, value: .bool(true))
        model.setModuleOutput(moduleId: b, pinIndex: 0, value: .bool(false))
        for _ in 0..<6 { model.step() }
        #expect(model.getNode(id: first)?.block.outPins.first?.asBool == false)
        #expect(model.getNode(id: second)?.block.outPins.first?.asBool == true)
    }

    @Test("A pin added, renamed or removed on the interface reaches every call, and wires keep their pins")
    @MainActor func interfaceEdits() throws {
        let (model, call) = try inverter()
        let inputs = try #require(model.project?.macroInterface(.inputs, onSheet: "*inv")).id
        model.addInterfacePin(moduleId: inputs)
        model.addInterfacePin(moduleId: inputs)
        #expect(model.module(id: call)?.inPins.map(\.name) == ["A", "A1", "A2"])
        model.renameInterfacePin(moduleId: inputs, pin: 1, to: "EN")
        #expect(model.module(id: call)?.inPins.map(\.name) == ["A", "EN", "A2"])

        // A wire on the third pin must still be on the pin called A2 once the second is gone.
        let src = try #require(model.addBlock(guid: BoolVarBlock.guid))
        #expect(model.connectPins(from: .init(moduleId: src, side: .output, index: 0), to: .init(moduleId: call, side: .input, index: 2)))
        model.removeInterfacePin(moduleId: inputs, pin: 1)
        let module = try #require(model.module(id: call))
        #expect(module.inPins.map(\.name) == ["A", "A2"])
        #expect(model.project?.inConnections.contains { $0.inModuleId == call && $0.inPinId == 1 && $0.outModuleId == src } == true)
    }

    @Test("Renaming a macro page renames its calls, and a macro cannot call itself or its caller")
    @MainActor func renameAndCycles() throws {
        let (model, call) = try inverter()
        #expect(model.renameMacroPage("*inv", to: "negace"))
        #expect(MacroCalls.target(of: try #require(model.module(id: call))) == "negace")
        #expect(model.project?.macroInterface(.inputs, onSheet: "*negace") != nil)
        #expect(model.project?.callableSheets(from: "*negace") == [], "a sheet is not offered to itself")
        let outer = try #require(model.addPage(caption: "outer", isMacro: true))
        #expect(model.callableMacros == ["*negace"])
        #expect(model.addMacroCall(sheet: "*negace") != nil)
        #expect(model.project?.callableSheets(from: "*negace").contains(outer) == false, "outer calls negace, so negace cannot call outer")
    }
}

@Suite("Macros made in the editor survive a save and compile")
struct MacroEditingRoundTripTests {
    @Test("Saved, re-read and compiled: the call, its pins and the sheet's blocks all come through")
    @MainActor func saveReloadCompile() throws {
        let editing = MacroEditingTests()
        let (model, call) = try editing.inverterForRoundTrip()
        let src = try #require(model.addBlock(guid: BoolVarBlock.guid))
        #expect(model.connectPins(from: .init(moduleId: src, side: .output, index: 0), to: .init(moduleId: call, side: .input, index: 0)))

        let xml = PCCSerializer().serialize(project: try #require(model.project))
        let again = try PCCParser().parse(xmlString: xml)
        let reread = try #require(again.modules.first { $0.id == call })
        #expect(MacroCalls.target(of: reread) == "inv")
        #expect(reread.inPins.map { $0.name } == ["A"])
        #expect(again.macroInterface(.outputs, onSheet: "*inv")?.inPins.first?.name == "Out1")
        #expect(PCCSerializer().serialize(project: again) == xml, "a second save changes nothing")

        let report = try #require(model.compileProject()).build.report
        #expect(report.macros.contains("inv1"), "\(report.macros)")
        #expect(report.unshaped.isEmpty, "\(report.unshaped)")
    }
}

extension MacroEditingTests {
    @MainActor func inverterForRoundTrip() throws -> (model: AppModel, call: Int) { try inverter() }
}
