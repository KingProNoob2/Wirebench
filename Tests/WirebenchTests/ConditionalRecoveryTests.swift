import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
@testable import WirebenchSource

/// A conditional whose work is `Set` writes is recovered as a source `if`: the language's `if` merges exactly like the
/// Dirigo gate does for a variable, and nothing inside is stateful beyond the variable being written.
@Suite("PLC Swift conditional recovery")
struct ConditionalRecoveryTests {
    private func conditionalProject() -> PCCProject {
        var project = PCCProject(name: "Cond", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        func block(_ name: String, id: Int, order: Int) -> PCCModule {
            let guid = BlockTypeCatalog.info(forBlockName: name)!.guid
            return BlockFactory.makeModule(guid: guid, id: id, name: "\(name)\(id)", x: 0, y: 0,
                                           order: order, threadId: 1, page: "Page")
        }
        var di = block("8xDI", id: 1, order: 10)
        var doBlock = block("8xDO", id: 2, order: 70)
        let ifBlock = block("If", id: 3, order: 20)
        let thenSet = block("Set", id: 4, order: 30)
        let elseBlock = block("Else", id: 5, order: 40)
        let elseSet = block("Set", id: 6, order: 50)
        let endIf = block("EndIf", id: 7, order: 60)
        let variable = block("BoolVar", id: 8, order: 80)
        _ = di; _ = doBlock
        project.modules = [di, doBlock, ifBlock, thenSet, elseBlock, elseSet, endIf, variable]
        project.inConnections = [
            Connection(inModuleId: ifBlock.id, inPinId: 0, outModuleId: di.id, outPinId: 0),
            Connection(inModuleId: thenSet.id, inPinId: 1, outModuleId: di.id, outPinId: 1),
            Connection(inModuleId: thenSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
            Connection(inModuleId: elseSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
            Connection(inModuleId: doBlock.id, inPinId: 1, outModuleId: variable.id, outPinId: 0),
        ]
        return project
    }

    @Test("An If/Else of Set writes comes back as if/else, and compiles")
    func recoversConditional() throws {
        let project = conditionalProject()
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("if di0 {"), "recovered source:\n\(source)")
        #expect(source.contains("} else {"))
        let again = try SwiftSourceCompiler().compile(source)
        #expect(again.project.modules.contains { $0.guid == BoolVarBlock.guid })
    }

    @Test("A conditional holding a timer is not recovered, and is reported")
    func leavesStatefulConditionals() throws {
        var project = conditionalProject()
        let guid = BlockTypeCatalog.info(forBlockName: "PulseGen")!.guid
        var timer = BlockFactory.makeModule(guid: guid, id: 9, name: "PulseGen1", x: 0, y: 0,
                                            order: 35, threadId: 1, page: "Page")
        timer.paramPins[0].value = .int32(5)
        timer.paramPins[1].value = .int32(5)
        project.modules.append(timer)
        let source = PCCDecompiler().source(for: project)
        #expect(!source.contains("if di0 {"), "a gated timer must not be recovered as an if")
        #expect(source.contains("Conditional blocks"))
    }
}
