import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchEngine
@testable import WirebenchLibrary

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
        let engine = TestEngine(project: Self.project([yes, not], [wire]))

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
        let engine = TestEngine(project: Self.project([first, second], [wire]))

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

        let engine = TestEngine(project: Self.project([ifModule, yesModule, endModule], []))

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

        let engine = TestEngine(project: Self.project([ifModule, yesModule, endModule], []))
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

    static func engine(selector: Int32) -> TestEngine {
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
        return TestEngine(project: p)
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
        let e = TestEngine(project: p)
        e.step()
        #expect(e.getNode(id: 6)?.block.outPins[0].asBool == false,
                "no arm may run when the switch's own condition is false")
    }


    /// The clock is a property of the engine, not a `Date()` call buried in the step.
    ///
    /// Two things depend on that. A time-dependent block must be *testable*, which means an engine can
    /// be shown a fixed instant. And one cycle must be stamped with **one** time: the engine used to
    /// call `Date()` once per scheduled thread, so two blocks in the same cycle could disagree — which
    /// is invisible until a block's output is a function of the clock.
    @Test("One cycle is stamped with one time, and the clock can be injected")
    func oneClockPerCycle() throws {
        var project = PCCProject(name: "clock")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: DateTimeBlock.guid, name: "DateTime1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))],
                      outPins: (0..<5).map { Pin(id: $0, value: .int32(0)) }),
        ]
        let engine = TestEngine(project: project, scheduling: .everyTick)

        // 2024-03-05 06:07:08 UTC. `SSemafor(1).pcc` shows the real shape: 1 in pin, 5 out pins.
        let fixed = Date(timeIntervalSince1970: 1_709_623_628)
        engine.now = { fixed }
        engine.step()

        guard let out = engine.getNode(id: 1)?.block.outPins.map(\.asInt) else {
            Issue.record("the fixture must expose DateTime1"); return
        }
        // D, H, M, S, DOW — `DirigoEpoch` counts days from 1 Jan 1980 and DOW from Monday, in its own
        // GMT calendar. The expectation is derived from that calendar rather than hardcoded: an earlier
        // version of this test asserted 06:07:08 UTC and read 07:27:08, which was the test being wrong
        // about the calendar, not the clock being wrong about the time.
        let parts = DirigoEpoch.calendar.dateComponents([.hour, .minute, .second], from: fixed)
        #expect(out.count >= 4, "the block must publish its parts")
        #expect(out[1] == Int32(parts.hour ?? -1), "hour must come from the injected clock")
        #expect(out[2] == Int32(parts.minute ?? -1), "minute must come from the injected clock")
        #expect(out[3] == Int32(parts.second ?? -1), "second must come from the injected clock")

        // Moving the clock moves the output, which is what makes the block testable at all: +3600 s is
        // exactly one hour later on the same calendar, whatever the zone.
        let later = DirigoEpoch.calendar.date(byAdding: .hour, value: 1, to: fixed) ?? fixed
        engine.now = { later }
        engine.step()
        let laterHour = DirigoEpoch.calendar.dateComponents([.hour], from: later).hour ?? -1
        let readback = engine.getNode(id: 1)?.block.outPins[1].asInt
        #expect(readback == Int(laterHour),
                "an hour later must read as the next hour, got \(String(describing: readback))")
    }
}
