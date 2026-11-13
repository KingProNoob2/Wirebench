import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchEngine
@testable import WirebenchModel

/// A new block has readable Y values, and Reset puts them back.
@Suite("Block output defaults")
struct BlockDefaultsTests {
    private func module(_ name: String, id: Int = 1) throws -> PCCModule {
        let guid = try #require(BlockTypeCatalog.info(forBlockName: name)?.guid)
        return BlockFactory.makeModule(guid: guid, id: id, name: "\(name)\(id)", x: 0, y: 0,
                                       order: 10, threadId: 1, page: "main")
    }

    @Test("A new block's outputs are typed zeros, not undefined")
    func factoryDefaults() throws {
        let and = try module("And")
        #expect(and.outPins.first?.value == .bool(false))
        let add = try module("IAdd")
        #expect(add.outPins.first?.value == .int32(0))
        let mul = try module("FMul")
        #expect(mul.outPins.first?.value == .float(0))
    }

    @Test("The engine shows defaults before a step and after a reset")
    func engineDefaults() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [try module("And")]
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        let and = project.modules[0]
        #expect(core.outPins(moduleId: and.id).allSatisfy { if case .undefined = $0 { return false } else { return true } })
        core.setIn(moduleId: and.id, pin: 0, value: .bool(true))
        core.setIn(moduleId: and.id, pin: 1, value: .bool(true))
        core.setIn(moduleId: and.id, pin: 2, value: .bool(true))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: and.id)[0] == .bool(true))
        core.reset()
        #expect(core.outPins(moduleId: and.id)[0] == .bool(false), "reset restores the default")
    }

    @MainActor
    @Test("Reset republishes default values to the canvas snapshots")
    func resetRepublishes() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [try module("And")]
        let model = AppModel()
        model.project = project
        model.selectedPage = "main"
        model.reset()   // installs the core for a project assigned directly
        let and = project.modules[0]
        for pin in 0..<3 { model.setModuleInput(moduleId: and.id, pinIndex: pin, value: .bool(true)) }
        model.step()
        #expect(model.snapshots[and.id]?.outValues.first == .bool(true))
        model.reset()
        #expect(model.snapshots[and.id]?.outValues.first == .bool(false), "no last-run value after Reset")
    }
}
