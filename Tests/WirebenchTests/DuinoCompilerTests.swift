import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchModel
import WirebenchMaraVM
@testable import WirebenchHardware

@Suite("Duino-S MFLW compiler")
struct DuinoCompilerTests {
    private func project(_ modules: [PCCModule], connections: [Connection] = []) -> PCCProject {
        var project = PCCProject(name: "duino-test")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = modules
        project.inConnections = connections
        return project
    }

    private func maraflowBlock(id: Int, _ definitionID: String, thread: Int = 1, order: Int = 10,
                               inputs: [PinValue], outputs: [PinValue],
                               props: [String: String] = [:]) -> PCCModule {
        let definition = MaraflowCatalog.byId[definitionID]!
        var attributes: [(String, String)] = [("MARAFLOW_DEF", definitionID)]
        for (key, value) in props { attributes.append(("MARAFLOW_PROP_\(key)", value)) }
        return PCCModule(id: id, guid: definition.guid, name: "\(definition.typeName)\(id)",
                         x: 0, y: 0, order: order, threadId: thread, page: "Main",
                         inPins: inputs.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         paramPins: [],
                         outPins: outputs.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         rawAttributes: AttributeBag(attributes))
    }

    private func wire(_ from: Int, _ out: Int, _ to: Int, _ input: Int) -> Connection {
        Connection(inModuleId: to, inPinId: input, outModuleId: from, outPinId: out)
    }

    @Test("A BOOL And compiles to a loadable MFLW image and runs in the firmware VM")
    func andRuns() throws {
        let and = maraflowBlock(id: 1, "Bool.And", inputs: [.bool(true), .bool(true), .bool(true)], outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([and]))
        #expect(result.image.count >= 72)
        #expect(Array(result.image[0..<2]) == [0x4D, 0x46]) // "MF"
        #expect(Array(result.image[2..<4]) == [0x4C, 0x57]) // "LW"
        let vm = MaraVM()
        try vm.load(result.image)
        #expect(vm.hasValidImage)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        let slot = try #require(result.slots["And1.Y"])
        #expect(vm.readBool(slot))
    }

    @Test("A wire carries the source value to a comparator")
    func wireRuns() throws {
        let source = maraflowBlock(id: 1, "Visual.Vars.IntVar", order: 10,
                                   inputs: [], outputs: [.int32(42)])
        let comparator = maraflowBlock(id: 2, "Main.Comparators.EQ", order: 20,
                                       inputs: [.bool(true), .int32(0), .int32(42)],
                                       outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([source, comparator],
                                                                connections: [wire(1, 0, 2, 1)]))
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        let resultSlot = try #require(result.slots["EQ2.Y"])
        #expect(vm.readBool(resultSlot))
    }

    @Test("A wire from a later block is readable by an earlier one")
    func feedbackWire() throws {
        let source = maraflowBlock(id: 2, "Visual.Vars.IntVar", order: 20,
                                   inputs: [], outputs: [.int32(7)])
        let comparator = maraflowBlock(id: 1, "Main.Comparators.EQ", order: 10,
                                       inputs: [.bool(true), .int32(0), .int32(7)],
                                       outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([comparator, source],
                                                                connections: [wire(2, 0, 1, 1)]))
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.readBool(try #require(result.slots["EQ1.Y"])))
    }

    @Test("DecodeDate and EncodeDate run on the firmware VM")
    func dateRoundTrip() throws {
        let decodeDefinition = try #require(MaraflowCatalog.byId["Main.Timers.DecodeDate"])
        var decode = BlockFactory.makeModule(guid: decodeDefinition.guid, id: 1, name: "DecodeDate1",
                                             x: 0, y: 0, order: 10, threadId: 1, page: "Main")
        decode.inPins[1].value = .int64(0)
        var project = PCCProject(name: "dates")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = [decode]
        let result = try DuinoCompiler.compile(project: project)
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.readInt(try #require(result.slots["DecodeDate1.Yr"])) == 1970)
        #expect(vm.readInt(try #require(result.slots["DecodeDate1.Mon"])) == 1)
        #expect(vm.readInt(try #require(result.slots["DecodeDate1.Day"])) == 1)

        let encodeDefinition = try #require(MaraflowCatalog.byId["Main.Timers.EncodeDate"])
        var encode = BlockFactory.makeModule(guid: encodeDefinition.guid, id: 2, name: "EncodeDate2",
                                             x: 0, y: 0, order: 20, threadId: 1, page: "Main")
        encode.inPins[1].value = .int32(1970)
        encode.inPins[2].value = .int32(1)
        encode.inPins[3].value = .int32(1)
        encode.inPins[4].value = .int32(0)
        encode.inPins[5].value = .int32(0)
        encode.inPins[6].value = .int32(0)
        project.modules = [encode]
        let encoded = try DuinoCompiler.compile(project: project)
        let vm2 = MaraVM()
        try vm2.load(encoded.image)
        try vm2.reset()
        try vm2.setRunning()
        try vm2.step(thread: 1)
        #expect(vm2.readLong(try #require(encoded.slots["EncodeDate2.Ts"])) == 0)
    }

    @Test("A timer counts elapsed time in the firmware VM")
    func timerRuns() throws {
        let timer = maraflowBlock(id: 1, "Main.Timers.Timer",
                                  inputs: [.bool(true), .bool(true), .int32(20)],
                                  outputs: [.bool(false), .int32(0)])
        let result = try DuinoCompiler.compile(project: project([timer]))
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        let q = try #require(result.slots["Timer1.Q"])
        let et = try #require(result.slots["Timer1.ET"])
        #expect(result.slotTypes[q] == .bool)
        #expect(result.slotTypes[et] == .int)
        for _ in 0..<4 { try vm.step(thread: 1, dtMicroseconds: 5_000) }
        #expect(vm.readInt(et) == 20)
        #expect(vm.readBool(q))
    }

    @Test("The nested macro project expands and compiles")
    func nestedMacros() throws {
        let project = NestedMacroTests.project()
        let result = try DuinoCompiler.compile(project: project)
        #expect(result.image.count > 72)
        #expect(!result.slots.isEmpty)
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.lastFaultCode == 0)
    }

    @Test("The image header names the Duino-S model and covers the payload with CRC32")
    func header() throws {
        let block = maraflowBlock(id: 1, "Bool.And", inputs: [.bool(true), .bool(true), .bool(true)], outputs: [.bool(false)])
        let image = try DuinoCompiler.compile(project: project([block])).image
        #expect(UInt16(image[6]) | (UInt16(image[7]) << 8) == 0x0407)
        #expect(UInt32(image[8]) | (UInt32(image[9]) << 8) | (UInt32(image[10]) << 16) | (UInt32(image[11]) << 24)
                == UInt32(image.count))
        let stored = UInt32(image[12]) | (UInt32(image[13]) << 8) | (UInt32(image[14]) << 16) | (UInt32(image[15]) << 24)
        #expect(stored == MaraProtFrame.crc32(image[72...]))
    }

    private func run(_ result: DuinoCompiler.Result, thread: Int = 1, steps: Int = 1,
                     dtMicroseconds: UInt32 = 5_000) throws -> MaraVM {
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        for _ in 0..<steps { try vm.step(thread: thread, dtMicroseconds: dtMicroseconds) }
        return vm
    }

    @Test("A counter counts up and down on edges and resets")
    func counterRuns() throws {
        let counter = maraflowBlock(id: 1, "Main.Timers.Counter",
                                    inputs: [.bool(true), .bool(false), .bool(false), .bool(false), .int32(2)],
                                    outputs: [.bool(false), .int32(0)])
        let result = try DuinoCompiler.compile(project: project([counter]))
        let vm = try run(result)
        let cu = try #require(result.slots["Counter1.CU"])
        let cd = try #require(result.slots["Counter1.CD"])
        let r = try #require(result.slots["Counter1.R"])
        let q = try #require(result.slots["Counter1.Q"])
        let cv = try #require(result.slots["Counter1.CV"])
        func pulse(_ slot: UInt16) throws {
            vm.writeBool(slot, true)
            try vm.step(thread: 1)
            vm.writeBool(slot, false)
            try vm.step(thread: 1)
        }
        try pulse(cu)
        #expect(vm.readInt(cv) == 1)
        #expect(!vm.readBool(q))
        try pulse(cu)
        #expect(vm.readInt(cv) == 2)
        #expect(vm.readBool(q))
        try pulse(cd)
        #expect(vm.readInt(cv) == 1)
        vm.writeBool(r, true)
        try vm.step(thread: 1)
        #expect(vm.readInt(cv) == 0)
        #expect(!vm.readBool(q))
    }

    @Test("A pulse generator alternates its output with the configured periods")
    func pulseGenRuns() throws {
        let pulse = maraflowBlock(id: 1, "Main.Timers.PulseGen",
                                  inputs: [.bool(true), .int32(10), .int32(10)],
                                  outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([pulse]))
        let vm = try run(result)
        let q = try #require(result.slots["PulseGen1.Q"])
        // 5 ms steps against a 10 ms high / 10 ms low cycle.
        #expect(vm.readBool(q))                    // t = 5 ms, high phase
        try vm.step(thread: 1)
        #expect(!vm.readBool(q))                   // t = 10 ms, low phase
        try vm.step(thread: 1)
        #expect(!vm.readBool(q))                   // t = 15 ms, low phase
        try vm.step(thread: 1)
        #expect(vm.readBool(q))                    // t = 0 ms, high phase again
    }

    @Test("A timer in TOF mode holds its output while the delay runs out")
    func timerTOFRuns() throws {
        let timer = maraflowBlock(id: 1, "Main.Timers.Timer",
                                  inputs: [.bool(true), .bool(true), .int32(10)],
                                  outputs: [.bool(false), .int32(0)],
                                  props: ["TimerMode": "TOF"])
        let result = try DuinoCompiler.compile(project: project([timer]))
        let vm = try run(result)
        let input = try #require(result.slots["Timer1.In"])
        let q = try #require(result.slots["Timer1.Q"])
        #expect(vm.readBool(q))                    // input still high: output follows
        vm.writeBool(input, false)
        try vm.step(thread: 1)                     // t = 5 ms of the 10 ms off-delay
        #expect(vm.readBool(q))
        try vm.step(thread: 1)                     // t = 10 ms: delay elapsed
        #expect(!vm.readBool(q))
    }

    @Test("A scale block maps an input float across the output range")
    func scaleRuns() throws {
        let scale = maraflowBlock(id: 1, "Math.Scale",
                                  inputs: [.bool(true), .float(50), .float(0), .float(100), .float(0), .float(10)],
                                  outputs: [.float(0)])
        let result = try DuinoCompiler.compile(project: project([scale]))
        let vm = try run(result)
        #expect(vm.readFloat(try #require(result.slots["Scale1.Y"])) == 5)
    }

    @Test("An in-range comparator normalises swapped bounds")
    func inRangeRuns() throws {
        let inRange = maraflowBlock(id: 1, "Main.Comparators.InRange",
                                    inputs: [.bool(true), .int32(5), .int32(10), .int32(0)],
                                    outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([inRange]))
        let vm = try run(result)
        #expect(vm.readBool(try #require(result.slots["InRange1.Y"])))
    }

    @Test("A hysteresis comparator latches between its thresholds")
    func hysteresisRuns() throws {
        let hysteresis = maraflowBlock(id: 1, "Main.Comparators.Hysteresis",
                                       inputs: [.bool(true), .float(0), .float(10), .float(20)],
                                       outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([hysteresis]))
        let vm = try run(result)
        let input = try #require(result.slots["Hysteresis1.In"])
        let y = try #require(result.slots["Hysteresis1.Y"])
        #expect(!vm.readBool(y))
        vm.writeFloat(input, 25)
        try vm.step(thread: 1)
        #expect(vm.readBool(y))
        vm.writeFloat(input, 15)
        try vm.step(thread: 1)
        #expect(vm.readBool(y))                    // inside the band: keeps the latched state
        vm.writeFloat(input, 5)
        try vm.step(thread: 1)
        #expect(!vm.readBool(y))
    }

    @Test("An array write is visible to a read on the same array, with out-of-bounds flagged")
    func arraysRun() throws {
        let write = maraflowBlock(id: 1, "Main.Arrays.ArrayWrite", order: 10,
                                  inputs: [.bool(true), .int32(3), .int32(42)],
                                  outputs: [.bool(false)])
        let read = maraflowBlock(id: 2, "Main.Arrays.ArrayRead", order: 20,
                                 inputs: [.bool(true), .int32(3)],
                                 outputs: [.int32(0), .bool(false)])
        let result = try DuinoCompiler.compile(project: project([write, read]))
        let vm = try run(result)
        let val = try #require(result.slots["ArrayRead2.Val"])
        let oob = try #require(result.slots["ArrayRead2.Oob"])
        #expect(vm.readInt(val) == 42)
        #expect(!vm.readBool(oob))
        vm.writeInt(try #require(result.slots["ArrayRead2.Idx"]), 99)
        try vm.step(thread: 1)
        #expect(vm.readInt(val) == 0)
        #expect(vm.readBool(oob))
    }

    @Test("A register written by one block is read back by another")
    func registersRun() throws {
        let write = maraflowBlock(id: 1, "Main.Execution.WriteReg", order: 10,
                                  inputs: [.bool(true), .int32(77)],
                                  outputs: [.int32(0)])
        let read = maraflowBlock(id: 2, "Main.Execution.ReadReg", order: 20,
                                 inputs: [.bool(true)],
                                 outputs: [.int32(0)])
        let result = try DuinoCompiler.compile(project: project([write, read]))
        let vm = try run(result)
        #expect(vm.readInt(try #require(result.slots["ReadReg2.Out"])) == 77)
    }

    @Test("A mux selects its input by address, a demux routes one input to the addressed output")
    func muxDemuxRun() throws {
        let mux = maraflowBlock(id: 1, "Main.Switches.Mux", order: 10,
                                inputs: [.bool(true), .int32(1), .int32(10), .int32(20)],
                                outputs: [.int32(0)])
        let demux = maraflowBlock(id: 2, "Main.Switches.Demux", order: 20,
                                  inputs: [.bool(true), .int32(1), .int32(7)],
                                  outputs: [.int32(0), .int32(0)])
        let result = try DuinoCompiler.compile(project: project([mux, demux]))
        let vm = try run(result)
        #expect(vm.readInt(try #require(result.slots["Mux1.Y"])) == 20)
        #expect(vm.readInt(try #require(result.slots["Demux2.Y0"])) == 0)
        #expect(vm.readInt(try #require(result.slots["Demux2.Y1"])) == 7)
    }

    @Test("Mux and demux hold their outputs when En is low")
    func muxDemuxEnableHolds() throws {
        let mux = maraflowBlock(id: 1, "Main.Switches.Mux", order: 10,
                                inputs: [.bool(true), .int32(1), .int32(10), .int32(20)], outputs: [.int32(0)])
        let demux = maraflowBlock(id: 2, "Main.Switches.Demux", order: 20,
                                  inputs: [.bool(true), .int32(1), .int32(7)], outputs: [.int32(0), .int32(0)])
        let result = try DuinoCompiler.compile(project: project([mux, demux]))
        let vm = try run(result)
        let muxEn = try #require(result.slots["Mux1.En"])
        let muxInput = try #require(result.slots["Mux1.X1"])
        let demuxEn = try #require(result.slots["Demux2.En"])
        let demuxInput = try #require(result.slots["Demux2.In"])
        #expect(vm.readInt(try #require(result.slots["Mux1.Y"])) == 20)
        #expect(vm.readInt(try #require(result.slots["Demux2.Y1"])) == 7)
        vm.writeBool(muxEn, false)
        vm.writeBool(demuxEn, false)
        vm.writeInt(muxInput, 99)
        vm.writeInt(demuxInput, 99)
        try vm.step(thread: 1)
        #expect(vm.readInt(try #require(result.slots["Mux1.Y"])) == 20)
        #expect(vm.readInt(try #require(result.slots["Demux2.Y1"])) == 7)
    }

    @Test("Date encode and decode compile with their timezone rules")
    func dateBlocksCompile() throws {
        let decode = maraflowBlock(id: 1, "Main.Timers.DecodeDate", order: 10,
                                   inputs: [.bool(true), .int64(0)],
                                   outputs: [.int32(0), .int32(0), .int32(0), .int32(0), .int32(0), .int32(0)],
                                   props: ["TimeZone": "Europe/Prague"])
        let encode = maraflowBlock(id: 2, "Main.Timers.EncodeDate", order: 20,
                                   inputs: [.bool(true), .int32(2026), .int32(1), .int32(1), .int32(0), .int32(0), .int32(0)],
                                   outputs: [.int64(0)], props: ["TimeZone": "Europe/Prague"])
        let result = try DuinoCompiler.compile(project: project([decode, encode]))
        let vm = try run(result)
        #expect(vm.readInt(try #require(result.slots["DecodeDate1.Yr"])) == 1970)
        #expect(vm.readInt(try #require(result.slots["DecodeDate1.Hr"])) == 1)
        #expect(vm.readInt(try #require(result.slots["EncodeDate2.Ts"])) == 1_767_222_000)
    }

    @Test("Configurable math uses the imported FLOAT pins in the firmware VM")
    func configurableFloatMath() throws {
        let add = maraflowBlock(id: 1, "Math.Add",
                                inputs: [.bool(true), .float(1.5), .float(2.25)], outputs: [.float(0)])
        let result = try DuinoCompiler.compile(project: project([add]))
        let output = try #require(result.slots["Add1.Y"])
        #expect(result.slotTypes[output] == .float)
        let vm = try run(result)
        #expect(vm.readFloat(output) == 3.75)
    }

    @Test("Variadic math emits every operand instead of dropping all but the first two")
    func variadicMath() throws {
        let add = maraflowBlock(id: 1, "Math.Add",
                                inputs: [.bool(true), .int32(1), .int32(2), .int32(3)], outputs: [.int32(0)])
        let result = try DuinoCompiler.compile(project: project([add]))
        let vm = try run(result)
        let output = try #require(result.slots["Add1.Y"])
        let value = vm.readInt(output)
        #expect(value == 6)
    }

    @Test("The timer's full TOF display label selects off-delay mode")
    func timerDisplayLabel() throws {
        let timer = maraflowBlock(id: 1, "Main.Timers.Timer",
                                  inputs: [.bool(true), .bool(true), .int32(10)],
                                  outputs: [.bool(false), .int32(0)],
                                  props: ["TimerMode": "TOF (Off-Delay)"])
        let result = try DuinoCompiler.compile(project: project([timer]))
        let vm = try run(result)
        let input = try #require(result.slots["Timer1.In"])
        let output = try #require(result.slots["Timer1.Q"])
        let initiallyHigh = vm.readBool(output)
        #expect(initiallyHigh)
        vm.writeBool(input, false)
        try vm.step(thread: 1)
        let duringDelay = vm.readBool(output)
        #expect(duringDelay)
        try vm.step(thread: 1)
        let afterDelay = vm.readBool(output)
        #expect(!afterDelay)
    }

    @Test("A disabled inverted Boolean output holds its value instead of toggling")
    func disabledInvertedOutputHolds() throws {
        var block = maraflowBlock(id: 1, "Bool.And",
                                  inputs: [.bool(true), .bool(true), .bool(true)], outputs: [.bool(false)])
        block.outPins[0].inverted = true
        let result = try DuinoCompiler.compile(project: project([block]))
        let vm = try run(result)
        let enable = try #require(result.slots["And1.En"])
        let output = try #require(result.slots["And1.Y"])
        let initial = vm.readBool(output)
        #expect(!initial)
        vm.writeBool(enable, false)
        try vm.step(thread: 1)
        let firstDisabledStep = vm.readBool(output)
        #expect(!firstDisabledStep)
        try vm.step(thread: 1)
        let secondDisabledStep = vm.readBool(output)
        #expect(!secondDisabledStep)
    }

    @Test("An inverted RS output is negated once while the latch keeps its internal state")
    func invertedRSOutput() throws {
        var block = maraflowBlock(id: 1, "Bool.RS",
                                  inputs: [.bool(true), .bool(true), .bool(false)],
                                  outputs: [.bool(false), .bool(false)])
        block.outPins[0].inverted = true
        let result = try DuinoCompiler.compile(project: project([block]))
        let vm = try run(result)
        let output = vm.readBool(try #require(result.slots["RS1.Q"]))
        #expect(!output)
    }

    @Test("Visual variables compile their configured CurrentValue")
    func visualVariableInitialValues() throws {
        let integer = maraflowBlock(id: 1, "Visual.Vars.IntVar", order: 10,
                                    inputs: [], outputs: [.int32(0)], props: ["CurrentValue": "37"])
        let long = maraflowBlock(id: 2, "Visual.Vars.LongVar", order: 20,
                                 inputs: [], outputs: [.int64(0)], props: ["CurrentValue": "5000000000"])
        let bool = maraflowBlock(id: 3, "Visual.Vars.BoolVar", order: 30,
                                 inputs: [], outputs: [.bool(false)], props: ["CurrentValue": "1"])
        let result = try DuinoCompiler.compile(project: project([integer, long, bool]))
        let vm = try run(result)
        #expect(vm.readInt(try #require(result.slots["IntVar1.Y"])) == 37)
        #expect(vm.readLong(try #require(result.slots["LongVar2.Y"])) == 5_000_000_000)
        #expect(vm.readBool(try #require(result.slots["BoolVar3.Y"])))
    }

    @Test("An inverted visual BoolVar keeps its configured value on every scan")
    func invertedVisualVariableIsStable() throws {
        var block = maraflowBlock(id: 1, "Visual.Vars.BoolVar", inputs: [], outputs: [.bool(false)])
        block.outPins[0].inverted = true
        let result = try DuinoCompiler.compile(project: project([block]))
        let vm = try run(result)
        let slot = try #require(result.slots["BoolVar1.Y"])
        let initial = vm.readBool(slot)
        #expect(initial)
        try vm.step(thread: 1)
        let next = vm.readBool(slot)
        #expect(next)
    }

    @Test("An e-stop check reports the machine as safe when nothing tripped")
    func eStopRuns() throws {
        let eStop = maraflowBlock(id: 1, "Main.Safety.EStop",
                                  inputs: [.bool(true), .bool(false)],
                                  outputs: [.bool(false), .bool(false), .int32(0)])
        let result = try DuinoCompiler.compile(project: project([eStop]))
        let vm = try run(result)
        #expect(vm.readBool(try #require(result.slots["EStop1.Safe"])))
        #expect(!vm.readBool(try #require(result.slots["EStop1.Trip"])))
        #expect(vm.readInt(try #require(result.slots["EStop1.Src"])) == 0)
    }
}
