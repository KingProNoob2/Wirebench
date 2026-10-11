import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoEngine
@testable import DirigoLibrary

@Suite("PulseGen")
struct PulseGenTests {
    @Test("The block itself oscillates")
    func blockOscillates() {
        let block = PulseGenBlock()
        block.inPins = [.bool(true), .bool(true)]      // En, Act
        block.paramPins = [.int32(3), .int32(2)]       // TOn, TOff
        var trace: [Bool] = []
        for _ in 0..<10 {
            block.process(sample: SampleContext())
            trace.append(block.outPins[1].asBool)
        }
        #expect(trace == [true, true, true, false, false, true, true, true, false, false],
                "got \(trace)")
    }

    @Test("Cnt counts cycles and Out pulses, per the help")
    func documentationSemantics() {
        let block = PulseGenBlock()
        block.inPins = [.bool(true), .bool(true)]
        block.paramPins = [.int32(3), .int32(2)]      // period 5
        var counts: [Int] = []
        var outs: [Bool] = []
        for _ in 0..<10 {
            block.process(sample: SampleContext())
            counts.append(block.outPins[0].asInt)
            outs.append(block.outPins[1].asBool)
        }
        // Cnt runs 1..5 and clears; it is not a copy of the pulse.
        #expect(counts == [1, 2, 3, 4, 5, 1, 2, 3, 4, 5], "got \(counts)")
        #expect(outs == [true, true, true, false, false, true, true, true, false, false])
    }

    @Test("Act=0 clears both outputs, whatever is wired")
    func actLowClearsEverything() {
        let block = PulseGenBlock()
        block.inPins = [.bool(true), .bool(true)]
        block.paramPins = [.int32(4), .int32(2)]
        // One tick is enough to be inside the TOn window.
        block.process(sample: SampleContext())
        #expect(block.outPins[1].asBool)

        // The help: "If Act=0 both outputs are cleared." The old code ran anyway when only En was
        // wired, so an unwired Act was ignored.
        block.inPins[1] = .bool(false)
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 0)
        #expect(block.outPins[1].asBool == false)
    }

    @Test("Through the engine it still oscillates")
    func engineOscillates() throws {
        var project = PCCProject(name: "pg")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1", x: 0, y: 0,
                      order: 10, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true))],
                      paramPins: [Pin(id: 0, value: .int32(3)), Pin(id: 1, value: .int32(2))],
                      outPins: [Pin(id: 0, value: .bool(false)), Pin(id: 1, value: .bool(false))]),
        ]
        let engine = SimulationEngine(project: project)
        var trace: [Bool] = []
        for _ in 0..<10 {
            engine.step()
            let node = engine.getNode(id: 1)
            trace.append(node?.block.outPins[1].asBool ?? false)
        }
        #expect(trace.contains(true) && trace.contains(false),
                "engine output never changes: \(trace)")
    }
}
