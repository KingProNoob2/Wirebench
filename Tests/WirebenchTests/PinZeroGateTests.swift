import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine

/// The engine gates a module on its first pin only when that pin is the block's `En` (the help's pin table). `Yes`,
/// `Int2Bits` and the limiters start with data; a false/zero first value must still run them.
@Suite("A block without En runs on a false first pin")
struct PinZeroGateTests {
    private func core(_ blockName: String) throws -> CxxSimulationCore {
        let guid = try #require(BlockTypeCatalog.info(forBlockName: blockName)?.guid)
        let module = BlockFactory.makeModule(guid: guid, id: 1, name: "\(blockName)1", x: 0, y: 0,
                                             order: 10, threadId: 1, page: "main")
        var project = PCCProject(name: blockName)
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [module]
        return CxxSimulationCore(project: project, profileScheduling: false)
    }

    @Test("Yes passes a false X through instead of holding its last true")
    func yesPassesFalse() throws {
        let core = try core("Yes")
        core.setIn(moduleId: 1, pin: 0, value: .bool(true))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 0)?.asBool == true)
        core.setIn(moduleId: 1, pin: 0, value: .bool(false))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 0)?.asBool == false)
    }

    @Test("LLimiter clamps an X of zero to Min")
    func limiterRunsWithZeroX() throws {
        let core = try core("LLimiter")
        core.setIn(moduleId: 1, pin: 0, value: .int32(0))
        core.setParam(moduleId: 1, pin: 0, value: .int32(2190))   // Max
        core.setParam(moduleId: 1, pin: 1, value: .int32(2164))   // Min
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 0)?.asInt == 2164)
    }
}
