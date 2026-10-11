import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoEngine
@testable import DirigoLibrary

/// The engine's execution model, ported from the original — see docs/spec/execution-model.md.
@Suite("Execution model")
struct ExecutionModelTests {
    static func module(_ id: Int, _ name: String, _ guid: UUID, x: Double = 0,
                       inPins: [PinValue] = [], outPins: [PinValue] = [],
                       order: Int = 0) -> PCCModule {
        PCCModule(id: id, guid: guid, name: name, x: x, y: 0,
                  order: order == 0 ? id * 10 : order, threadId: 1, page: "main",
                  inPins: inPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                  outPins: outPins.enumerated().map { Pin(id: $0.offset, value: $0.element) })
    }

    static func project(_ modules: [PCCModule], _ connections: [Connection]) -> PCCProject {
        var p = PCCProject(name: "exec")
        p.pages = [ProjectPage(caption: "main")]
        p.modules = modules
        p.inConnections = connections
        return p
    }

    @Test("A forward wire is fresh in the same pass, not a pass late")
    func forwardWireIsFresh() {
        // Yes1 passes its input straight through; Not1 inverts. 1 -> 0 -> 0.
        let yes = Self.module(1, "Yes1", YesBlock.guid,
                              inPins: [.bool(true)], outPins: [.bool(true)])
        let not = Self.module(2, "Not1", NotBlock.guid,
                              inPins: [.bool(true), .bool(false)], outPins: [.bool(false)])
        let wire = Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 0)
        let engine = SimulationEngine(project: Self.project([yes, not], [wire]))

        engine.step()
        // Yes runs first (order 10 before 20) and writes true; Not must see that value *this* pass.
        #expect(engine.getNode(id: 2)?.block.inPins[1].asBool == true)
        #expect(engine.getNode(id: 2)?.block.outPins[0].asBool == false)   // not(true)
    }

    @Test("A wire feeding backwards is one pass stale")
    func feedbackIsOnePassStale() {
        // 2 -> 1, so the consumer (1) runs before the producer (2) and reads last pass's value.
        let first = Self.module(1, "Not1", NotBlock.guid,
                                inPins: [.bool(true), .bool(false)], outPins: [.bool(false)], order: 10)
        let second = Self.module(2, "Yes1", YesBlock.guid,
                                 inPins: [.bool(true)], outPins: [.bool(true)], order: 20)
        let wire = Connection(inModuleId: 1, inPinId: 1, outModuleId: 2, outPinId: 0)
        let engine = SimulationEngine(project: Self.project([first, second], [wire]))

        engine.step()
        // Nothing has produced yet on the very first pass, so Not sees its own stored default.
        #expect(engine.getNode(id: 2)?.block.outPins[0].asBool == true)
        engine.step()
        // Now the consumer sees what the producer wrote on the previous pass.
        #expect(engine.getNode(id: 1)?.block.inPins[1].asBool == true)
    }

    @Test("Blocks inside a false branch do not run, and hold their values")
    func ifGatingHoldsBlocks() {
        // Not1 (order 10) then If1 (order 20) with En = false, then And-ish work, then EndIf.
        var ifModule = Self.module(2, "If1", IfBlock.guid, inPins: [.bool(false)], outPins: [.bool(false)])
        ifModule.order = 20
        var yesModule = Self.module(3, "Yes1", YesBlock.guid,
                                    inPins: [.bool(true)], outPins: [.bool(true)])
        yesModule.order = 30
        var endModule = Self.module(4, "EndIf1", EndIfBlock.guid, outPins: [.bool(false)])
        endModule.order = 40

        let engine = SimulationEngine(project: Self.project([ifModule, yesModule, endModule], []))

        // Pass 1: the branch is open, so Yes1 runs and passes true through.
        engine.getNode(id: 2)?.block.inPins[0] = .bool(true)
        engine.getNode(id: 3)?.block.inPins[0] = .bool(true)
        engine.step()
        #expect(engine.getNode(id: 3)?.block.outPins[0].asBool == true)

        // Pass 2: close the branch and change what the block *would* compute.
        engine.getNode(id: 2)?.block.inPins[0] = .bool(false)
        engine.getNode(id: 3)?.block.inPins[0] = .bool(false)
        engine.step()

        // The gated block must not have executed, so its output holds the previous value.
        #expect(engine.getNode(id: 3)?.block.outPins[0].asBool == true,
                "a block in a false branch must hold, not recompute")
        // The construct did not unbalance the stack: a block after EndIf still runs.
        #expect(engine.getNode(id: 4)?.block.outPins[0].asBool == true)
    }

    @Test("A true branch runs normally")
    func ifTrueBranchRuns() {
        var endModule = Self.module(4, "EndIf1", EndIfBlock.guid, outPins: [.bool(false)])
        endModule.order = 40
        var yesModule = Self.module(3, "Yes1", YesBlock.guid,
                                    inPins: [.bool(false)], outPins: [.bool(true)])
        yesModule.order = 30
        var ifModule = Self.module(2, "If1", IfBlock.guid, inPins: [.bool(true)], outPins: [.bool(false)])
        ifModule.order = 20

        let engine = SimulationEngine(project: Self.project([ifModule, yesModule, endModule], []))
        engine.step()
        #expect(engine.getNode(id: 3)?.block.outPins[0].asBool == false,
                "inside a true branch the block must execute")
    }
}

@Suite("Switch construct")
struct SwitchConstructTests {
    static func module(_ id: Int, _ name: String, _ guid: UUID,
                       inPins: [PinValue] = [], attrs: [String: String] = [:]) -> PCCModule {
        var a = AttributeBag()
        for (k, v) in attrs { a[k] = v }
        return PCCModule(id: id, guid: guid, name: name, x: 0, y: 0, order: id * 10,
                         threadId: 1, page: "main",
                         inPins: inPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         rawAttributes: a)
    }

    static func engine(selector: Int32) -> SimulationEngine {
        let sw = module(2, "Switch1", SwitchBlock.guid,
                        inPins: [.bool(true), .int32(selector)])
        let case5 = module(3, "Case5", CaseBlock.guid, attrs: ["VALUES": "5..7"])
        let def = module(4, "Default1", DefaultBlock.guid)
        let end = module(5, "EndSwitch1", EndSwitchBlock.guid)
        // A probe inside each arm: Yes1 passes a value through, and we look at whether it ran.
        var inCase = module(6, "Yes1", YesBlock.guid, inPins: [.bool(true)])
        inCase.order = 35
        var inDefault = module(7, "Yes2", YesBlock.guid, inPins: [.bool(true)])
        inDefault.order = 45
        var p = PCCProject(name: "switch")
        p.pages = [ProjectPage(caption: "main")]
        p.modules = [sw, case5, inCase, def, inDefault, end]
        return SimulationEngine(project: p)
    }

    @Test("Case parsing accepts single values and ranges")
    func caseValueParsing() {
        let block = CaseBlock(valuesSpec: "1, 5..7, 9")
        #expect(block.accepts(1))
        #expect(block.accepts(5) && block.accepts(6) && block.accepts(7))
        #expect(block.accepts(9))
        #expect(!block.accepts(2) && !block.accepts(8))
        #expect(CaseBlock(valuesSpec: "3-4").accepts(4))
        #expect(CaseBlock(valuesSpec: "junk, 2").accepts(2), "unparsable items are ignored")
    }

    @Test("The matching Case arm runs and the Default arm does not")
    func matchingCaseRuns() {
        let e = Self.engine(selector: 6)      // 6 is inside 5..7
        e.step()
        // Yes1 sits inside Case5's arm (order 35, before Default at 40).
        #expect(e.getNode(id: 6)?.block.outPins[0].asBool == true)
        // Yes2 sits inside the Default arm; no case matched? one did, so it must not run.
        #expect(e.getNode(id: 7)?.block.outPins[0].asBool == false,
                "Default must not run when a case matched")
    }

    @Test("An unmatched selector falls through to Default")
    func unmatchedFallsThroughToDefault() {
        let e = Self.engine(selector: 2)      // matches nothing
        e.step()
        #expect(e.getNode(id: 6)?.block.outPins[0].asBool == false,
                "the case arm must not run when the selector does not match")
        #expect(e.getNode(id: 7)?.block.outPins[0].asBool == true,
                "Default must run when nothing matched")
    }

    @Test("A disabled Switch disables every arm")
    func disabledSwitchDisablesArms() {
        let sw = Self.module(2, "Switch1", SwitchBlock.guid, inPins: [.bool(false), .int32(6)])
        let case5 = Self.module(3, "Case5", CaseBlock.guid, attrs: ["VALUES": "5"])
        var inCase = Self.module(6, "Yes1", YesBlock.guid, inPins: [.bool(true)])
        inCase.order = 35
        let end = Self.module(5, "EndSwitch1", EndSwitchBlock.guid)
        var p = PCCProject(name: "switch")
        p.pages = [ProjectPage(caption: "main")]
        p.modules = [sw, case5, inCase, end]
        let e = SimulationEngine(project: p)
        e.step()
        #expect(e.getNode(id: 6)?.block.outPins[0].asBool == false,
                "no arm may run when the switch's own condition is false")
    }

}
