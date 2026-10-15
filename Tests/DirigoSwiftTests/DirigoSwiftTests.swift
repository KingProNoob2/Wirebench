import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoLibrary
@testable import DirigoEngine

@Suite("DirigoSwift Core & Engine Tests")
struct DirigoSwiftTests {
    let sampleProjectPath = "/Users/erik/Nextcloud/Random Stuff/dirigo-antigravity/rulkoshaddirigo.pcc"

    @Test("Test parsing rulkoshaddirigo.pcc")
    func testParseSampleProject() throws {
        let parser = PCCParser()
        let url = URL(fileURLWithPath: sampleProjectPath)
        let project = try parser.parse(fileAt: url)

        #expect(project.application == "Dirigo")
        #expect(project.pages.count == 4)
        #expect(project.modules.count == 57)
        #expect(project.inConnections.count >= 40)
        #expect(project.paramConnections.count >= 3)
    }

    @Test("Test lossless XML serialization roundtrip")
    func testXMLRoundtrip() throws {
        let parser = PCCParser()
        let serializer = PCCSerializer()
        let url = URL(fileURLWithPath: sampleProjectPath)
        let origProject = try parser.parse(fileAt: url)

        let xmlString = serializer.serialize(project: origProject)
        #expect(!xmlString.isEmpty)

        let reparsedProject = try parser.parse(xmlString: xmlString)
        #expect(reparsedProject.modules.count == origProject.modules.count)
        #expect(reparsedProject.inConnections.count == origProject.inConnections.count)
        #expect(reparsedProject.paramConnections.count == origProject.paramConnections.count)
        #expect(reparsedProject.pages.count == origProject.pages.count)
    }

    @Test("Test logic function blocks")
    func testLogicBlocks() {
        let sample = SampleContext()

        // AND Block
        let andBlock = AndBlock(inputCount: 2)
        andBlock.inPins[0] = .bool(true) // Enable
        andBlock.inPins[1] = .bool(true)
        andBlock.inPins[2] = .bool(false)
        andBlock.process(sample: sample)
        #expect(andBlock.outPins[0].asBool == false)

        andBlock.inPins[2] = .bool(true)
        andBlock.process(sample: sample)
        #expect(andBlock.outPins[0].asBool == true)

        // OR Block
        let orBlock = OrBlock(inputCount: 2)
        orBlock.inPins[0] = .bool(true)
        orBlock.inPins[1] = .bool(false)
        orBlock.inPins[2] = .bool(true)
        orBlock.process(sample: sample)
        #expect(orBlock.outPins[0].asBool == true)

        // NOT Block
        let notBlock = NotBlock()
        notBlock.inPins[0] = .bool(true)
        notBlock.inPins[1] = .bool(false)
        notBlock.process(sample: sample)
        #expect(notBlock.outPins[0].asBool == true)
    }

    @Test("Test math and routing blocks")
    func testMathBlocks() {
        let sample = SampleContext()

        // Comparator (In0: En, In1: A, In2: B)
        let comp = ComparatorBlock()
        comp.inPins[0] = .bool(true)
        comp.inPins[1] = .int32(10)
        comp.inPins[2] = .int32(5)
        comp.process(sample: sample)
        #expect(comp.outPins[0].asBool == true) // AGtB
        #expect(comp.outPins[1].asBool == false) // AEqB
        #expect(comp.outPins[2].asBool == false) // ALtB

        // Int2Bits
        let int2Bits = Int2BitsBlock(bitCount: 8)
        int2Bits.inPins[0] = .int32(5) // binary: 00000101 -> bit 0 = 1, bit 1 = 0, bit 2 = 1
        int2Bits.process(sample: sample)
        #expect(int2Bits.outPins[0].asBool == true)
        #expect(int2Bits.outPins[1].asBool == false)
        #expect(int2Bits.outPins[2].asBool == true)

        // Div (In0: En, In1: A, In2: B)
        let div = DivBlock()
        div.inPins[0] = .bool(true)
        div.inPins[1] = .int32(17)
        div.inPins[2] = .int32(5)
        div.process(sample: sample)
        #expect(div.outPins[0].asInt == 3) // Quotient
        #expect(div.outPins[1].asInt == 2) // Remainder
    }

    @Test("Test full project simulation execution")
    func testSimulationExecution() throws {
        let parser = PCCParser()
        let url = URL(fileURLWithPath: sampleProjectPath)
        let project = try parser.parse(fileAt: url)

        let engine = SimulationEngine(project: project)
        #expect(engine.nodes.count == 57)

        // Run 50 simulation ticks
        engine.run(ticks: 50)
        #expect(engine.tickCount == 50)
    }

    @Test("Test PulseGen and Counter integration")
    func testPulseGenAndCounterIntegration() {
        let pulseGen = PulseGenBlock()
        pulseGen.inPins[0] = .bool(true) // En
        pulseGen.inPins[1] = .bool(true) // Act
        pulseGen.paramPins[0] = .int32(1) // TOn = 1
        pulseGen.paramPins[1] = .int32(1) // TOff = 1

        let counter = CounterBlock()
        counter.inPins[0] = .bool(true) // En

        let sample = SampleContext()
        for _ in 0..<10 {
            pulseGen.process(sample: sample)
            counter.inPins[1] = pulseGen.outPins[1] // Wire PulseGen.Out -> Counter.Tr
            counter.process(sample: sample)
        }

        #expect(counter.outPins[0].asInt > 0)
    }

    @Test("Test PulseGen runs indefinitely without stopping")
    func testPulseGenIndefiniteOscillation() {
        let pulseGen = PulseGenBlock()
        pulseGen.inPins[0] = .bool(true) // En
        pulseGen.inPins[1] = .bool(true) // Act
        pulseGen.paramPins[0] = .int32(2) // TOn = 2 cycles
        pulseGen.paramPins[1] = .int32(3) // TOff = 3 cycles (Period = 5)

        let sample = SampleContext()
        var highCount = 0
        var risingEdges = 0
        var lastOut = false

        // Run for 150 cycles (should produce exactly 30 full periods, 60 high cycles, 30 pulses)
        for _ in 0..<150 {
            pulseGen.process(sample: sample)
            let currentOut = pulseGen.outPins[1].asBool
            if currentOut { highCount += 1 }
            if !lastOut && currentOut { risingEdges += 1 }
            lastOut = currentOut
        }

        #expect(risingEdges == 30)
        #expect(highCount == 60)
        // Cnt is an integer cycle counter, not a copy of the pulse: it must reach TOn+TOff and
        // then clear, rather than sitting high for TOn of every period.
        var maxCnt = 0
        for _ in 0..<5 {
            pulseGen.process(sample: sample)
            maxCnt = max(maxCnt, pulseGen.outPins[0].asInt)
        }
        #expect(maxCnt == 5, "Cnt should count up to TOn+TOff = 5, got \(maxCnt)")

        // Now turn OFF the input signal (Act = false)
        pulseGen.inPins[1] = .bool(false)
        for _ in 0..<20 {
            pulseGen.process(sample: sample)
            #expect(pulseGen.outPins[0].asBool == false)
            #expect(pulseGen.outPins[1].asBool == false)
        }

        // Now turn HIGH the input signal again -> resumes switching!
        pulseGen.inPins[1] = .bool(true)
        pulseGen.process(sample: sample)
        #expect(pulseGen.outPins[0].asBool == true)
        #expect(pulseGen.outPins[1].asBool == true)
    }

    @Test("Test SinglePulse monostable one-shot fires only once per trigger")
    func testSinglePulseMonostableOneShot() {
        let singlePulse = SinglePulseBlock()
        singlePulse.inPins[0] = .bool(true)  // En
        singlePulse.inPins[1] = .bool(false) // Tr
        singlePulse.paramPins[0] = .int32(3) // TOn = 3 cycles

        let sample = SampleContext()

        // 1. Initial idle state
        singlePulse.process(sample: sample)
        #expect(singlePulse.outPins[1].asBool == false)
        #expect(singlePulse.outPins[0].asInt == 0)

        // 2. Rising edge on Tr
        singlePulse.inPins[1] = .bool(true)
        singlePulse.process(sample: sample) // Cycle 1 of pulse
        #expect(singlePulse.outPins[1].asBool == true)
        #expect(singlePulse.outPins[0].asInt == 1)

        singlePulse.process(sample: sample) // Cycle 2 of pulse
        #expect(singlePulse.outPins[1].asBool == true)
        #expect(singlePulse.outPins[0].asInt == 2)

        singlePulse.process(sample: sample) // Cycle 3 of pulse
        #expect(singlePulse.outPins[1].asBool == true)
        #expect(singlePulse.outPins[0].asInt == 3)

        // 3. Pulse finished: stays false even though Tr is still held high!
        for _ in 0..<50 {
            singlePulse.process(sample: sample)
            #expect(singlePulse.outPins[1].asBool == false)
            #expect(singlePulse.outPins[0].asInt == 0)
        }

        // 4. Release Tr (falling edge) -> remains false
        singlePulse.inPins[1] = .bool(false)
        singlePulse.process(sample: sample)
        #expect(singlePulse.outPins[1].asBool == false)

        // 5. New rising edge -> fires exactly one new pulse!
        singlePulse.inPins[1] = .bool(true)
        singlePulse.process(sample: sample)
        #expect(singlePulse.outPins[1].asBool == true)
        #expect(singlePulse.outPins[0].asInt == 1)
    }

    @Test("Test Macro integration and mode switching")
    func testMacroIntegrationAndModeSwitching() throws {
        let parser = PCCParser()
        let url = URL(fileURLWithPath: sampleProjectPath)
        let project = try parser.parse(fileAt: url)
        let engine = SimulationEngine(project: project)

        // Step 1: Initial state
        engine.step()

        let rultea1Node = engine.getNode(id: 50)!
        let inputs1Node = engine.getNode(id: 10)!

        #expect(rultea1Node.block.inPins[0].asBool == true)
        #expect(inputs1Node.block.outPins[0].asBool == true)

        // Trigger RoztoctRuletu on *rultea
        let spinNode = engine.getNode(id: 58)!
        if let spinBlock = spinNode.block as? BoolVarBlock {
            spinBlock.trigger()
        }

        // Run 20 ticks
        engine.run(ticks: 20)

        let counter3Node = engine.getNode(id: 20)!
        #expect(counter3Node.block.outPins[0].asInt > 0)

        // Step 2: Switch mode to Kostka (Dice) via PrepinacRezim (ID 55)
        let modeSwitchNode = engine.getNode(id: 55)!
        if let modeSwitch = modeSwitchNode.block as? BoolVarBlock {
            modeSwitch.trigger()
        }
        engine.run(ticks: 5)

        let kostka1Node = engine.getNode(id: 49)!
        let inputs2Node = engine.getNode(id: 1)!
        #expect(kostka1Node.block.inPins[0].asBool == true)
        #expect(inputs2Node.block.outPins[0].asBool == true)

        // Run 20 ticks for Dice simulation
        engine.run(ticks: 20)
        let counter1Node = engine.getNode(id: 5)!
        // The sheet's PulseGen (ID 2) is clocked by its `Act` pin, which this save leaves unwired at constant 0
        // (only `En` comes in through the macro's one input): with `Act=0` both outputs stay cleared, so the
        // counter has nothing to count — what a PLC running this file would do too. Switching `Act` on, as
        // editing that constant would, starts the dice's clock and the counter runs.
        #expect(counter1Node.block.outPins[0].asInt == 0, "Act is 0: the generator stays cleared")
        let pulseGenNode = engine.getNode(id: 2)!
        pulseGenNode.block.inPins[1] = .bool(true)
        engine.run(ticks: 20)
        #expect(counter1Node.block.outPins[0].asInt > 0)

        // Step 3: Switch mode to Had (Snake) via PrepinacRezim
        if let modeSwitch = modeSwitchNode.block as? BoolVarBlock {
            modeSwitch.trigger()
        }
        engine.run(ticks: 5)

        let had1Node = engine.getNode(id: 48)!
        let inputs3Node = engine.getNode(id: 40)!
        #expect(had1Node.block.inPins[0].asBool == true)
        #expect(inputs3Node.block.outPins[0].asBool == true)

        // Trigger snake run via BoolVar1 (ID 41) on *had
        let hadStartNode = engine.getNode(id: 41)!
        if let hadStart = hadStartNode.block as? BoolVarBlock {
            hadStart.trigger()
        }
        engine.run(ticks: 20)
        let counter4Node = engine.getNode(id: 31)!
        #expect(counter4Node.block.outPins[0].asInt > 0)
    }

    @Test("Test BoolVar single-click immediate activation without movement")
    func testBoolVarSingleStepImmediateActivation() throws {
        let parser = PCCParser()
        let url = URL(fileURLWithPath: sampleProjectPath)
        let project = try parser.parse(fileAt: url)
        let engine = SimulationEngine(project: project)

        // Initial setup step
        engine.step()

        // 1. Test PrepinacRezim (ID 55 on main)
        let modeSwitchNode = engine.getNode(id: 55)!
        guard let modeSwitch = modeSwitchNode.block as? BoolVarBlock else {
            Issue.record("Expected BoolVarBlock for ID 55")
            return
        }

        let orPrepinacNode = engine.getNode(id: 56)!
        #expect(orPrepinacNode.block.outPins[0].asBool == false)

        // Trigger button click on PrepinacRezim
        modeSwitch.trigger()
        engine.propagateWires()
        engine.step()

        // Mode switch output and OrPrepinac output must immediately be true
        #expect(modeSwitch.outPins[0].asBool == true)
        #expect(orPrepinacNode.block.inPins[2].asBool == true)
        #expect(orPrepinacNode.block.outPins[0].asBool == true)

        // 2. Test BoolVar1 (ID 41 on *had)
        let or2Node = engine.getNode(id: 39)!
        let boolVarNode = engine.getNode(id: 41)!
        guard let boolVar = boolVarNode.block as? BoolVarBlock else {
            Issue.record("Expected BoolVarBlock for ID 41")
            return
        }

        #expect(boolVar.outPins[0].asBool == false)

        // Trigger button click
        boolVar.trigger()
        engine.propagateWires()

        // Output and connected wire on Or2 pin 2 must immediately be true without moving module
        #expect(boolVar.outPins[0].asBool == true)
        #expect(or2Node.block.inPins[2].asBool == true)
    }

    @Test("Test newly implemented function blocks from IDP catalog")
    func testAdvancedFunctionBlocks() {
        let sample = SampleContext()

        // 1. Math Blocks
        let sub = SubBlock()
        sub.inPins = [.bool(true), .int32(100), .int32(42)]
        sub.process(sample: sample)
        #expect(sub.outPins[0].asInt == 58)

        let absBlock = AbsBlock()
        absBlock.inPins = [.bool(true), .int32(-25)]
        absBlock.process(sample: sample)
        #expect(absBlock.outPins[0].asInt == 25)

        let incBlock = IncBlock()
        incBlock.inPins = [.bool(true), .int32(10)]
        incBlock.process(sample: sample)
        #expect(incBlock.outPins[0].asInt == 11, "Y = X + 1; IInc has no parameters")

        let negBlock = NegBlock()
        negBlock.inPins = [.bool(true), .int32(50)]
        negBlock.process(sample: sample)
        #expect(negBlock.outPins[0].asInt == -50)

        // The help gives ILimiter no En: X in, Max/Min as parameters, Y out.
        let limiter = LimiterBlock()
        limiter.inPins = [.int32(150)]
        limiter.paramPins = [.int32(100), .int32(0)]     // Max, Min
        limiter.process(sample: sample)
        #expect(limiter.outPins[0].asInt == 100)

        let inRange = InRangeBlock()
        inRange.inPins = [.bool(true), .int32(45), .int32(10), .int32(50)]
        inRange.process(sample: sample)
        #expect(inRange.outPins[0].asBool == true)

        let mean = MeanBlock(windowSize: 4)
        // Help order is En, Tr, X: the middle pin is the store trigger and the last is the value.
        for value in [10, 20, 30, 40] {
            mean.inPins = [.bool(true), .bool(true), .int32(Int32(value))]
            mean.process(sample: sample)
        }
        #expect(mean.outPins[0].asInt == 25)

        // The help gives CalibTransf En/X in and XMax/XMid/XMin, YMax/YMid/YMin as parameters, so
        // the calibration points are configuration rather than Swift-side state.
        let calib = CalibratedTransformBlock()
        calib.paramPins = [.int32(100), .int32(50), .int32(0),    // XMax, XMid, XMin
                           .int32(200), .int32(100), .int32(0)]   // YMax, YMid, YMin
        calib.inPins = [.bool(true), .int32(50)]
        calib.process(sample: sample)
        #expect(calib.outPins[0].asInt == 100, "X = XMid maps to YMid")

        calib.inPins = [.bool(true), .int32(0)]
        calib.process(sample: sample)
        #expect(calib.outPins[0].asInt == 0, "X <= XMin maps to YMin")

        calib.inPins = [.bool(true), .int32(200)]
        calib.process(sample: sample)
        #expect(calib.outPins[0].asInt == 200, "X > XMax maps to YMax")

        let fmath = FloatMathBlock(operation: .mul)
        fmath.inPins = [.float(3.5), .float(2.0)]
        fmath.process(sample: sample)
        #expect(fmath.outPins[0].asFloat == 7.0)

        // 2. Bitwise and Routing Blocks
        let yes = YesBlock(pinCount: 2)
        yes.inPins = [.int32(77), .int32(88)]
        yes.process(sample: sample)
        #expect(yes.outPins[0].asInt == 77)
        #expect(yes.outPins[1].asInt == 88)

        let bits2Int = Bits2IntBlock(totalPins: 5)   // En + 4 bits
        // In 0 is En, then B0...: 1 + 0 + 4 + 8 = 13
        bits2Int.inPins = [.bool(true), .bool(true), .bool(false), .bool(true), .bool(true)]
        bits2Int.process(sample: sample)
        #expect(bits2Int.outPins[0].asInt == 13)

        let shl = ShlBlock()
        shl.inPins = [.bool(true), .int32(3), .int32(2)] // 3 << 2 = 12
        shl.process(sample: sample)
        #expect(shl.outPins[0].asInt == 12)

        let sar = SarBlock()
        sar.inPins = [.bool(true), .int32(16), .int32(2)] // 16 >> 2 = 4
        sar.process(sample: sample)
        #expect(sar.outPins[0].asInt == 4)

        let ext = ExtBlock()
        ext.inPins = [.bool(true), .int32(0x0F0), .int32(4), .int32(4)] // bits 4..7 -> 0xF = 15
        ext.process(sample: sample)
        #expect(ext.outPins[0].asInt == 15)

        let ins = InsBlock()
        ins.inPins = [.bool(true), .int32(0x00), .int32(0xF), .int32(4), .int32(4)]
        ins.process(sample: sample)
        #expect(ins.outPins[0].asInt == 0xF0)

        let pulse = SinglePulseBlock()
        pulse.paramPins = [.int32(2)]
        pulse.inPins = [.bool(true)]
        pulse.process(sample: sample)
        #expect(pulse.outPins[0].asBool == true)
        pulse.process(sample: sample)
        #expect(pulse.outPins[0].asBool == true)
        pulse.process(sample: sample)
        #expect(pulse.outPins[0].asBool == false)

        // 3. Control & Regulation Blocks
        let timerTon = TimerBlock(mode: .onDelay)
        timerTon.paramPins = [.int32(3)]
        timerTon.inPins = [.bool(true), .bool(true), .bool(false)]   // En, In, Rst
        timerTon.process(sample: sample)
        #expect(timerTon.outPins[0].asBool == false)
        timerTon.process(sample: sample)
        #expect(timerTon.outPins[0].asBool == false)
        timerTon.process(sample: sample)
        #expect(timerTon.outPins[0].asBool == true)

        let hyst = HysteresisComparatorBlock()
        hyst.inPins = [.float(12.0), .float(10.0), .float(5.0)]
        hyst.process(sample: sample)
        #expect(hyst.outPins[0].asBool == true)
        hyst.inPins = [.float(7.0), .float(10.0), .float(5.0)]
        hyst.process(sample: sample)
        #expect(hyst.outPins[0].asBool)          // AGtB latched
        // Inside the hysteresis band the comparison holds rather than flipping.
        // HalfHyst 6 makes the band [B-h, B+h] = [-1, 11], which contains A = 10.
        hyst.paramPins = [.int32(6)]
        hyst.inPins = [.bool(true), .int32(10), .int32(5)]
        hyst.process(sample: sample)
        #expect(hyst.outPins[1].asBool, "AEqB reports the band")
        #expect(hyst.outPins[0].asBool, "AGtB holds inside the band")

        let ifB = IfBlock()
        ifB.inPins = [.bool(true)]
        ifB.process(sample: sample)
        #expect(ifB.outPins[0].asBool == true)

        // `Else` is likewise a label with no pins; the engine flips the condition bit for it.
        let elseB = ElseBlock()
        elseB.process(sample: sample)
        #expect(elseB.outPins.isEmpty)

        // `Case` is a label inside a `Switch`: it has no pins of its own, and its accepted values
        // are configuration ("VALUES"), matched against the switch's captured selector.
        let caseB = CaseBlock(valuesSpec: "1, 3..5")
        #expect(caseB.accepts(3))
        #expect(caseB.accepts(5))
        #expect(!caseB.accepts(2))

        // 4. Data & Array Blocks
        let intVar = IntVarBlock(initialValue: 10)
        #expect(intVar.outPins[0].asInt == 10)
        // The help gives IntVar no inputs: its value is written by `Set`/`SetIdx`, which the engine
        // performs by overwriting this block's output pin.
        intVar.setValue(99)
        intVar.process(sample: sample)
        #expect(intVar.outPins[0].asInt == 99)

        let arrayId = 1
        let createArr = CreateArrayBlock()
        // Help pins: CreateIntArray is En, Id, Len -> St.
        IntArrayStore.shared.reset()
        createArr.inPins = [.bool(true), .int32(Int32(arrayId)), .int32(5)]
        createArr.process(sample: sample)
        #expect(createArr.outPins[0].asBool, "St reports success")

        // WriteIntArray is En, Id, Idx, X -> Y.
        let writeArr = WriteArrayBlock()
        writeArr.inPins = [.bool(true), .int32(Int32(arrayId)), .int32(2), .int32(456)]
        writeArr.process(sample: sample)
        #expect(writeArr.outPins[0].asInt == 456, "Y echoes the value written")

        // ReadIntArray is En, Id, Idx -> Y.
        let readArr = ReadArrayBlock()
        readArr.inPins = [.bool(true), .int32(Int32(arrayId)), .int32(2)]
        readArr.process(sample: sample)
        #expect(readArr.outPins[0].asInt == 456)

        // 5. Value Display Formatting
        let valDisp = ValueDisplayBlock(format: "{1:Zapnuto|0:Vypnuto}")
        valDisp.inPins = [.int32(1)]
        valDisp.process(sample: sample)
        #expect(valDisp.formattedText == "Zapnuto")

        let valHex = ValueDisplayBlock(format: "0x")
        valHex.inPins = [.int32(255)]
        valHex.process(sample: sample)
        #expect(valHex.formattedText == "0x00FF")
    }

    @Test("Test BlockRegistry factory creation for newly registered blocks")
    func testBlockRegistryFactories() {
        let registry = BlockRegistry.shared

        func makeMod(name: String, guid: UUID) -> PCCModule {
            PCCModule(id: 1, guid: guid, name: name, x: 0, y: 0, order: 0, threadId: 0, page: "main", inPins: [], paramPins: [], outPins: [])
        }

        let subMod = makeMod(name: "Sub1", guid: SubBlock.guid)
        let subBlock = registry.create(for: subMod)
        #expect(subBlock is SubBlock)

        let timerMod = makeMod(name: "Timer1", guid: TimerBlock.guid)
        let timerBlock = registry.create(for: timerMod)
        #expect(timerBlock is TimerBlock)

        let valMod = makeMod(name: "Value1", guid: ValueDisplayBlock.guid)
        let valBlock = registry.create(for: valMod)
        #expect(valBlock is ValueDisplayBlock)

        let arrayMod = makeMod(name: "CreateIntArray1", guid: CreateArrayBlock.guid)
        let arrBlock = registry.create(for: arrayMod)
        #expect(arrBlock is CreateArrayBlock)

        let equiMod = makeMod(name: "Equitherm1", guid: EquithermBlock.guid)
        let equiBlock = registry.create(for: equiMod)
        #expect(equiBlock is EquithermBlock)
    }

    @Test("Test decompiled blocks and adapted logic")
    func testDecompiledBlocksAndLogic() {
        let sample = SampleContext()

        // 1. Comparator with 2 pins (A, B) vs 3 pins (En, A, B)
        let comp2 = ComparatorBlock()
        comp2.inPins = [.int32(50), .int32(20)]
        comp2.process(sample: sample)
        #expect(comp2.outPins[0].asBool == true)  // AGtB
        #expect(comp2.outPins[1].asBool == false) // AEqB
        #expect(comp2.outPins[2].asBool == false) // ALtB

        // 2. Trigger with pulse on change
        let trig1 = TriggerBlock()
        trig1.inPins = [.bool(true), .int32(10)]   // En, X
        trig1.process(sample: sample)
        #expect(trig1.outPins[0].asBool == false) // first sample establishes baseline
        trig1.inPins = [.bool(true), .int32(25)]
        trig1.process(sample: sample)
        #expect(trig1.outPins[0].asBool == true)  // change detected!
        trig1.process(sample: sample)
        #expect(trig1.outPins[0].asBool == false) // back to 0

        // 3. Counter with 2 pins (Tr, Rst)
        let cnt2 = CounterBlock()
        cnt2.inPins = [.bool(false), .bool(false)]
        cnt2.process(sample: sample)
        cnt2.inPins = [.bool(true), .bool(false)]
        cnt2.process(sample: sample)
        #expect(cnt2.outPins[0].asInt == 1)

        // 4. Equitherm heating curve
        // Help pins: En, OT in; AX/AY/BX/BY are parameters, not inputs. The curve through
        // A(-15, 70) and B(20, 20) at OT = 0 gives about 48.6.
        let eq = EquithermBlock()
        eq.paramPins = [.int32(-15), .int32(70), .int32(20), .int32(20)]
        eq.inPins = [.bool(true), .int32(0)]
        eq.process(sample: sample)
        let wt = eq.outPins[0].asInt
        #expect(wt > 45 && wt < 55)

        // 5. Copy block
        let cp = CopyBlock(count: 2, hasWrPin: true)
        cp.inPins = [.bool(true), .int32(111), .int32(222)]
        cp.process(sample: sample)
        #expect(cp.outPins[0].asInt == 111)
        #expect(cp.outPins[1].asInt == 222)
        // Disable Wr -> values held
        cp.inPins = [.bool(false), .int32(999), .int32(888)]
        cp.process(sample: sample)
        #expect(cp.outPins[0].asInt == 111)

        // 6. Demux
        let demux = IntDemuxBlock(outputCount: 4)
        demux.inPins = [.bool(true), .int32(2), .int32(99)]
        demux.process(sample: sample)
        #expect(demux.outPins[2].asInt == 99)
        #expect(demux.outPins[0].asInt == 0)

        // 7. Advanced Counter
        let advCnt = AdvCounterBlock()
        advCnt.inPins[0] = .bool(true)
        advCnt.inPins[1] = .bool(true) // Up rising
        advCnt.inPins[5] = .int32(10) // Limit
        advCnt.process(sample: sample)
        #expect(advCnt.outPins[0].asInt == 1)
        #expect(advCnt.outPins[2].asBool == false) // L is false because count > 0

        // 8. Filter block
        let flt = FilterBlock()
        flt.inPins = [.bool(true), .int32(100)]      // En, X
        flt.paramPins = [.int32(10)]                 // T = 10 cycles
        flt.process(sample: sample)
        // One cycle of a first-order lag: 100/10 = 10, and it keeps approaching 100.
        #expect(flt.outPins[0].asInt == 10)
        for _ in 0..<200 { flt.process(sample: sample) }
        #expect(flt.outPins[0].asInt >= 99, "the output converges on the input")

        // 9. Bitwise operations
        let iand = IntAndBlock()
        iand.inPins = [.bool(true), .int32(0b1100), .int32(0b1010)]   // En, X0, X1
        iand.process(sample: sample)
        #expect(iand.outPins[0].asInt == 0b1000)

        let ior = IntOrBlock()
        ior.inPins = [.bool(true), .int32(0b1100), .int32(0b1010)]
        ior.process(sample: sample)
        #expect(ior.outPins[0].asInt == 0b1110)

        let inot = IntNotBlock()
        inot.inPins = [.bool(true), .int32(0)]
        inot.process(sample: sample)
        #expect(inot.outPins[0].asInt == -1)
    }

    @Test("Test creating, saving, and loading a PCC project file")
    func testPCCFileSaverAndLoaderLifecycle() throws {
        // 1. Create a new empty project in memory
        var proj = PCCProject(
            application: "Dirigo",
            applicationVersion: "v2.5.9.449",
            name: "MyMacSavedProject",
            profile: "Sybas P3",
            pageSize: 60,
            pages: [ProjectPage(caption: "main"), ProjectPage(caption: "*submacro")],
            modules: []
        )
        #expect(proj.pages.count == 2)
        #expect(proj.modules.isEmpty)

        // 2. Add modules and connections
        let andMod = PCCModule(
            id: 101,
            guid: AndBlock.guid,
            name: "And1",
            x: 120,
            y: 80,
            order: 10,
            threadId: 0,
            page: "main",
            inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true)), Pin(id: 2, value: .bool(true))],
            paramPins: [],
            outPins: [Pin(id: 0, value: .bool(false))]
        )
        proj.modules.append(andMod)

        // 3. Save to a temporary .pcc file
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Dirigo_Test_\(UUID().uuidString).pcc")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let serializer = PCCSerializer()
        let xmlContent = serializer.serialize(project: proj)
        try xmlContent.write(to: tempURL, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: tempURL.path))

        // 4. Load it back using PCCParser
        let parser = PCCParser()
        let loadedProj = try parser.parse(fileAt: tempURL)

        #expect(loadedProj.application == "Dirigo")
        #expect(loadedProj.name == "MyMacSavedProject")
        #expect(loadedProj.pages.count == 2)
        #expect(loadedProj.modules.count == 1)
        #expect(loadedProj.modules.first?.id == 101)
        #expect(loadedProj.modules.first?.name == "And1")
    }

    @Test("Test PulseGen in ruleta_kostka_had simulation")
    func testRuletaKostkaHadPulseGen() throws {
        let pccPath = "/Users/erik/Nextcloud/Random Stuff/dirigo-antigravity/ruleta_kostka_had.pcc"
        guard FileManager.default.fileExists(atPath: pccPath) else { return }
        let parser = PCCParser()
        let project = try parser.parse(fileAt: URL(fileURLWithPath: pccPath))
        let engine = SimulationEngine(project: project)

        // Switch to Kostka mode: PrepinacRezim (ID 2)
        let prepinac = engine.getNode(id: 2)!
        (prepinac.block as! BoolVarBlock).trigger() // toggle mode from 0 (Had) to 1 (Kostka)
        engine.step()

        let tlacitkoGo = engine.getNode(id: 3)!
        let pgKostka = engine.getNode(id: 42)! // PulseGenKostka

        print("--- BEFORE GO PRESSED ---")
        for i in 0..<5 {
            engine.step()
            print("Tick \(i): PulseGen.inPins=\(pgKostka.block.inPins) outPins=\(pgKostka.block.outPins)")
        }

        print("--- GO PRESSED (HIGH) ---")
        (tlacitkoGo.block as! BoolVarBlock).outPins[0] = .bool(true)
        (tlacitkoGo.block as! BoolVarBlock).isPulseMode = false

        for i in 0..<10 {
            engine.step()
            print("Tick \(i) [GO=1]: PulseGen.inPins=\(pgKostka.block.inPins) outPins=\(pgKostka.block.outPins)")
        }

        print("--- GO RELEASED (OFF) ---")
        (tlacitkoGo.block as! BoolVarBlock).outPins[0] = .bool(false)
        for i in 0..<5 {
            engine.step()
            print("Tick \(i) [GO=0]: PulseGen.inPins=\(pgKostka.block.inPins) outPins=\(pgKostka.block.outPins)")
        }
    }

    @Test("Test PulseGen in rulkoshaddirigo simulation")
    func testRulkoshaddirigoPulseGen() throws {
        let pccPath = "/Users/erik/Nextcloud/Random Stuff/dirigo-antigravity/rulkoshaddirigo.pcc"
        guard FileManager.default.fileExists(atPath: pccPath) else { return }
        let parser = PCCParser()
        let project = try parser.parse(fileAt: URL(fileURLWithPath: pccPath))
        let engine = SimulationEngine(project: project)

        // PulseGen1 (ID 2 on *kostka)
        let pg1 = engine.getNode(id: 2)!
        print("=== rulkoshaddirigo PulseGen1 (ID 2) ===")
        for i in 0..<10 {
            engine.step()
            print("Tick \(i): pg1.inPins=\(pg1.block.inPins) outPins=\(pg1.block.outPins)")
        }

        // PulseGen2 (ID 11 on *rultea)
        let pg2 = engine.getNode(id: 11)!
        print("=== rulkoshaddirigo PulseGen2 (ID 11) ===")
        for i in 0..<10 {
            engine.step()
            print("Tick \(i): pg2.inPins=\(pg2.block.inPins) outPins=\(pg2.block.outPins)")
        }

        // PulseGen4 (ID 25 on *had)
        let pg4 = engine.getNode(id: 25)!
        print("=== rulkoshaddirigo PulseGen4 (ID 25) ===")
        for i in 0..<10 {
            engine.step()
            print("Tick \(i): pg4.inPins=\(pg4.block.inPins) outPins=\(pg4.block.outPins)")
        }

        // PulseGen5 (ID 36 on *had)
        let pg5 = engine.getNode(id: 36)!
        print("=== rulkoshaddirigo PulseGen5 (ID 36) ===")
        for i in 0..<10 {
            engine.step()
            print("Tick \(i): pg5.inPins=\(pg5.block.inPins) outPins=\(pg5.block.outPins)")
        }
    }
}

