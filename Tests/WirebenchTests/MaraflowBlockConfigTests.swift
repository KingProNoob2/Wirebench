import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel
@testable import WirebenchEngine
import WirebenchMaraVM

@Suite("Maraflow block configuration")
@MainActor
struct MaraflowBlockConfigTests {
    private func model(_ definitionID: String) -> AppModel {
        let definition = MaraflowCatalog.byId[definitionID]!
        let module = BlockFactory.makeModule(guid: definition.guid, id: 1, name: "\(definition.typeName)1",
                                             x: 0, y: 0, order: 10, threadId: 1, page: "Main")
        var project = PCCProject(name: "Configuration")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = [module]
        let model = AppModel()
        model.project = project
        return model
    }

    @Test("Variadic math exposes input count and datatype and applies both")
    func variadicMathConfiguration() throws {
        let model = model("Math.Add")
        let config = try #require(BlockConfig.make(of: model, moduleId: 1))
        #expect(config.fields.contains { $0.key == "inputs" && $0.kind == "int" })
        #expect(config.fields.contains { $0.key == "dataType" && $0.kind == "choice" })

        BlockConfig.apply(["inputs": "4", "dataType": "FLOAT"], to: 1, in: model)
        let module = try #require(model.module(id: 1))
        #expect(module.inPins.map(\.name) == ["En", "X1", "X2", "X3", "X4"])
        #expect(module.inPins.dropFirst().allSatisfy { $0.value.asFloat == 0 })
        #expect(module.outPins[0].value == .float(0))
        #expect(module.rawAttributes["MARAFLOW_PROP_InputCount"] == "4")
        #expect(module.rawAttributes["MARAFLOW_PROP_DataType"] == "FLOAT")
        let exported = String(decoding: try MaraflowExporter.export(model.project!).data, as: UTF8.self)
        #expect(exported.contains("InputCount") && exported.contains("DataType") && exported.contains("FLOAT"))

        BlockConfig.apply(["inputs": "2"], to: 1, in: model)
        #expect(model.module(id: 1)?.inPins.count == 3)
    }

    @Test("Configurable comparators default to their numeric operand type")
    func comparatorDataTypeDefaults() throws {
        let eq = model("Main.Comparators.EQ")
        #expect(MaraflowConfiguration.dataType(of: try #require(eq.module(id: 1))) == "INT")
        let hysteresis = model("Main.Comparators.Hysteresis")
        #expect(MaraflowConfiguration.dataType(of: try #require(hysteresis.module(id: 1))) == "FLOAT")
    }

    @Test("Mux keeps its address pin while changing channels and datatype")
    func muxConfiguration() throws {
        let model = model("Main.Switches.Mux")
        BlockConfig.apply(["inputs": "4", "dataType": "FLOAT"], to: 1, in: model)
        let module = try #require(model.module(id: 1))
        #expect(module.inPins.map(\.name) == ["En", "Adr", "X0", "X1", "X2", "X3"])
        #expect(module.inPins[1].value == .int32(0))
        #expect(module.inPins[2].value == .float(0))
        #expect(module.outPins[0].value == .float(0))
    }

    @Test("Demux exposes its datatype option")
    func demuxConfiguration() throws {
        let model = model("Main.Switches.Demux")
        let config = try #require(BlockConfig.make(of: model, moduleId: 1))
        #expect(config.fields.contains { $0.key == "dataType" && $0.kind == "choice" })
    }

    @Test("Boolean coils expose operands and preserve their truth table")
    func booleanCoilOperands() throws {
        let normal = model("Ladder.Coil.NORMAL")
        #expect(try #require(BlockConfig.make(of: normal, moduleId: 1)).fields.contains { $0.key == "operand" })
        BlockConfig.apply(["operand": "DO2"], to: 1, in: normal)
        let core = CxxSimulationCore(project: normal.project!, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO2") == 1)
        core.setIn(moduleId: 1, pin: 0, value: .bool(false))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO2") == 0)

        let negated = model("Ladder.Coil.NEGATED")
        BlockConfig.apply(["operand": "DO2"], to: 1, in: negated)
        let notCore = CxxSimulationCore(project: negated.project!, profileScheduling: false)
        notCore.setIn(moduleId: 1, pin: 0, value: .bool(false))
        notCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(notCore.operandValue("DO2") == 1)

        let set = model("Ladder.Coil.SET")
        BlockConfig.apply(["operand": "DO2"], to: 1, in: set)
        let setCore = CxxSimulationCore(project: set.project!, profileScheduling: false)
        setCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        setCore.setIn(moduleId: 1, pin: 0, value: .bool(false))
        setCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(setCore.operandValue("DO2") == 1)

        let reset = model("Ladder.Coil.RESET")
        BlockConfig.apply(["operand": "DO2"], to: 1, in: reset)
        let resetCore = CxxSimulationCore(project: reset.project!, profileScheduling: false)
        resetCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(resetCore.operandValue("DO2") == 0)
    }

    @Test("Edge coils pulse only on their configured transition")
    func edgeCoilOperands() throws {
        let rising = model("Ladder.Coil.POS")
        BlockConfig.apply(["operand": "DO2"], to: 1, in: rising)
        let core = CxxSimulationCore(project: rising.project!, profileScheduling: false)
        core.setIn(moduleId: 1, pin: 0, value: .bool(false))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        core.setIn(moduleId: 1, pin: 0, value: .bool(true))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO2") == 1)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO2") == 0)

        let falling = model("Ladder.Coil.NEG")
        BlockConfig.apply(["operand": "DO2"], to: 1, in: falling)
        let negCore = CxxSimulationCore(project: falling.project!, profileScheduling: false)
        negCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        negCore.setIn(moduleId: 1, pin: 0, value: .bool(false))
        negCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(negCore.operandValue("DO2") == 1)
        negCore.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(negCore.operandValue("DO2") == 0)
    }

    @Test("Normal coil compiles its operand and IO write")
    func normalCoilCompiles() throws {
        let model = model("Ladder.Coil.NORMAL")
        BlockConfig.apply(["operand": "DO2"], to: 1, in: model)
        let compiled = try DuinoCompiler.compile(project: model.project!)
        let coilOpcode = compiled.image.firstIndex(of: 0x1B)
        #expect(coilOpcode != nil)
        let ioWrite = compiled.image.firstIndex(of: 0x71)
        #expect(ioWrite != nil)
        #expect(compiled.image[ioWrite! + 4] == 2 && compiled.image[ioWrite! + 5] == 0)
    }

    @Test("Analog coil exposes and uses its destination operand")
    func analogCoilOperand() async throws {
        let model = model("Ladder.Coil.ANALOG")
        model.project?.modules[0].inPins[1].value = .int32(2048)
        let config = try #require(BlockConfig.make(of: model, moduleId: 1))
        #expect(config.fields.contains { $0.key == "operand" && $0.kind == "text" })
        BlockConfig.apply(["operand": "AO1"], to: 1, in: model)
        #expect(model.module(id: 1)?.rawAttributes["MARAFLOW_PROP_Operand"] == "AO1")

        let core = CxxSimulationCore(project: model.project!, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("AO1") == 2048)
        core.setIn(moduleId: 1, pin: 0, value: .bool(false))
        core.setIn(moduleId: 1, pin: 1, value: .int32(3000))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("AO1") == 2048, "a disabled coil holds the old output")

        let compiled = try DuinoCompiler.compile(project: model.project!)
        let enable = try #require(compiled.slots.first { $0.key.hasSuffix(".En") }?.value)
        let source = try #require(compiled.slots.first { $0.key.hasSuffix(".In") }?.value)
        let expected: [UInt8] = [0x71, 0x03, UInt8(truncatingIfNeeded: enable), UInt8(truncatingIfNeeded: enable >> 8),
                                 0x01, 0x00, UInt8(truncatingIfNeeded: source), UInt8(truncatingIfNeeded: source >> 8)]
        let emitsAO1 = compiled.image.indices.contains { index in
            index + expected.count <= compiled.image.count && Array(compiled.image[index..<(index + expected.count)]) == expected
        }
        #expect(emitsAO1, "the coil emits IO_WRITE for AO1 rather than an unsupported-block error")
        let exported = String(decoding: try MaraflowExporter.export(model.project!).data, as: UTF8.self)
        #expect(exported.contains("Operand") && exported.contains("AO1"))
    }

    @Test("Register coil writes its configured register")
    func registerCoilOperand() throws {
        let model = model("Ladder.Coil.WRITE_REG")
        model.project?.modules[0].inPins[1].value = .int32(99)
        let config = try #require(BlockConfig.make(of: model, moduleId: 1))
        #expect(config.fields.contains { $0.key == "operand" && $0.kind == "text" })
        BlockConfig.apply(["operand": "REG_7"], to: 1, in: model)
        let core = CxxSimulationCore(project: model.project!, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("REG_7") == 99)
        let compiled = try DuinoCompiler.compile(project: model.project!)
        let vm = MaraVM()
        try vm.load(compiled.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.readInt(try #require(compiled.slots["REG.REG_7"])) == 99)
    }

    @Test("I/O channels are configurable and change the pin and compiler type")
    func ioChannelConfiguration() throws {
        let model = model("IO.IREF")
        let config = try #require(BlockConfig.make(of: model, moduleId: 1))
        #expect(config.fields.contains { $0.key == "property.Channel" && $0.kind == "choice" })
        BlockConfig.apply(["property.Channel": "AI2"], to: 1, in: model)
        let module = try #require(model.module(id: 1))
        #expect(module.rawAttributes["MARAFLOW_PROP_Channel"] == "AI2")
        #expect(module.outPins[0].value == .int32(0))
        let compiled = try DuinoCompiler.compile(project: model.project!)
        #expect(compiled.image.indices.contains { index in
            index + 8 <= compiled.image.count && compiled.image[index] == 0x70 && compiled.image[index + 1] == 2
                && compiled.image[index + 6] == 2 && compiled.image[index + 7] == 0
        })
    }

    @Test("Timer, date and interrupt properties are editable")
    func executionPropertyConfiguration() throws {
        let timer = model("Main.Timers.Timer")
        #expect(try #require(BlockConfig.make(of: timer, moduleId: 1)).fields.contains { $0.key == "property.TimerMode" })
        BlockConfig.apply(["property.TimerMode": "TOF (Off-Delay)"], to: 1, in: timer)
        #expect(timer.module(id: 1)?.rawAttributes["MARAFLOW_PROP_TimerMode"] == "TOF (Off-Delay)")

        let date = model("Main.Timers.DecodeDate")
        let dateFields = try #require(BlockConfig.make(of: date, moduleId: 1)).fields
        #expect(dateFields.contains { $0.key == "property.TimeZone" })
        #expect(dateFields.contains { $0.key == "property.TzStdOffsetMin" && $0.kind == "int" })
        BlockConfig.apply(["property.TimeZone": "Europe/Prague"], to: 1, in: date)
        let prague = try #require(date.module(id: 1))
        #expect(prague.rawAttributes["MARAFLOW_PROP_TzStdOffsetMin"] == "60")
        #expect(prague.rawAttributes["MARAFLOW_PROP_TzDstStartWeek"] == "-1")
        #expect(try #require(BlockConfig.make(of: date, moduleId: 1)).fields.first {
            $0.key == "property.TzStdOffsetMin"
        }?.value == "60")
        #expect(try #require(BlockConfig.make(of: date, moduleId: 1)).fields.first {
            $0.key == "property.TzStdOffsetMin"
        }?.disabled == true)
        BlockConfig.apply(["property.TimeZone": "Custom"], to: 1, in: date)
        #expect(try #require(BlockConfig.make(of: date, moduleId: 1)).fields.first {
            $0.key == "property.TzStdOffsetMin"
        }?.disabled == false)

        let interrupt = model("Main.Execution.Interrupt")
        let fields = try #require(BlockConfig.make(of: interrupt, moduleId: 1)).fields
        for key in ["InterruptSource", "TriggerEdge", "CaptureMode", "LatchPolicy", "SimPulseValue"] {
            #expect(fields.contains { $0.key == "property.\(key)" })
        }
        BlockConfig.apply(["property.InterruptSource": "EXTI_DI3", "property.SimPulseValue": "42"], to: 1, in: interrupt)
        #expect(interrupt.module(id: 1)?.rawAttributes["MARAFLOW_PROP_InterruptSource"] == "EXTI_DI3")
        #expect(interrupt.module(id: 1)?.rawAttributes["MARAFLOW_PROP_SimPulseValue"] == "42")
    }

    @Test("A native variable press advances the rest of the program once")
    func visualControlRunsOneScan() throws {
        let model = model("Visual.Vars.BoolVar")
        let definition = MaraflowCatalog.byId["Main.Timers.Counter"]!
        var counter = BlockFactory.makeModule(guid: definition.guid, id: 2, name: "Counter2",
                                              x: 0, y: 0, order: 20, threadId: 1, page: "Main")
        counter.inPins[1].value = .bool(true)
        model.project?.modules.append(counter)
        model.runtimeDidChangeStructure()
        model.setModuleInputPressed(moduleId: 1, pinIndex: 0, isPressed: true)
        #expect(model.getNode(id: 2)?.block.outPins[1].asInt == 1)
        #expect(model.tickCount == 1)
    }

    @Test("Visual numeric variables persist slider and switch edits with their configured ranges")
    func visualNumericVariableControls() throws {
        let slider = model("Visual.Vars.IntVar")
        BlockConfig.apply(["property.InputType": "Slider", "property.ValA": "10", "property.ValB": "90",
                           "property.CurrentValue": "20"], to: 1, in: slider)
        let sliderModule = try #require(slider.module(id: 1))
        #expect(BlockInteraction.classify(sliderModule) == .slider)
        #expect(BlockRole.isIntVariable(sliderModule))
        #expect(BlockRole.sliderMin(of: sliderModule) == 10)
        #expect(BlockRole.sliderMax(of: sliderModule) == 90)
        slider.setVariableValue(moduleId: 1, value: 42)
        #expect(slider.getNode(id: 1)?.block.outPins.first?.asInt == 42)
        #expect(slider.module(id: 1)?.rawAttributes["MARAFLOW_PROP_CurrentValue"] == "42")
        slider.step()
        #expect(slider.getNode(id: 1)?.block.outPins.first?.asInt == 42)

        let long = model("Visual.Vars.LongVar")
        long.runtimeDidChangeStructure()
        long.setVariableValue(moduleId: 1, value: 5_000_000_000)
        #expect(long.getNode(id: 1)?.block.outPins.first?.asInt == 5_000_000_000)
        #expect(long.module(id: 1)?.rawAttributes["MARAFLOW_PROP_CurrentValue"] == "5000000000")
        long.step()
        #expect(long.getNode(id: 1)?.block.outPins.first?.asInt == 5_000_000_000)

        let switcher = model("Visual.Vars.IntVar")
        BlockConfig.apply(["property.InputType": "Switch", "property.ValA": "10", "property.ValB": "90",
                           "property.CurrentValue": "10"], to: 1, in: switcher)
        #expect(BlockInteraction.classify(try #require(switcher.module(id: 1))) == .control)
        switcher.toggleModuleInput(moduleId: 1, pinIndex: 0)
        #expect(switcher.getNode(id: 1)?.block.outPins.first?.asInt == 90)
        switcher.step()
        #expect(switcher.getNode(id: 1)?.block.outPins.first?.asInt == 90)
        switcher.toggleModuleInput(moduleId: 1, pinIndex: 0)
        #expect(switcher.getNode(id: 1)?.block.outPins.first?.asInt == 10)
    }

    @Test("Visual BoolVar toggle and momentary controls retain their runtime values")
    func visualBoolVarControls() throws {
        let toggle = model("Visual.Vars.BoolVar")
        BlockConfig.apply(["property.SwitchMode": "Toggle"], to: 1, in: toggle)
        #expect(BlockRole.boolVarMode(of: toggle.module(id: 1)!) == .toggleSwitch)
        toggle.setModuleInputPressed(moduleId: 1, pinIndex: 0, isPressed: true)
        #expect(toggle.getNode(id: 1)?.block.outPins.first?.asBool == true)
        #expect(toggle.module(id: 1)?.rawAttributes["MARAFLOW_PROP_CurrentValue"] == "1")
        toggle.step()
        #expect(toggle.getNode(id: 1)?.block.outPins.first?.asBool == true)
        toggle.setModuleInputPressed(moduleId: 1, pinIndex: 0, isPressed: false)
        toggle.setModuleInputPressed(moduleId: 1, pinIndex: 0, isPressed: true)
        #expect(toggle.getNode(id: 1)?.block.outPins.first?.asBool == false)

        let momentary = model("Visual.Vars.BoolVar")
        BlockConfig.apply(["property.SwitchMode": "Momentary"], to: 1, in: momentary)
        #expect(BlockRole.boolVarMode(of: momentary.module(id: 1)!) == .pushButton)
        momentary.setModuleInputPressed(moduleId: 1, pinIndex: 0, isPressed: true)
        #expect(momentary.getNode(id: 1)?.block.outPins.first?.asBool == true)
        momentary.step()
        #expect(momentary.getNode(id: 1)?.block.outPins.first?.asBool == true)
        momentary.setModuleInputPressed(moduleId: 1, pinIndex: 0, isPressed: false)
        #expect(momentary.getNode(id: 1)?.block.outPins.first?.asBool == false)
        #expect(momentary.module(id: 1)?.rawAttributes["MARAFLOW_PROP_CurrentValue"] == "0")
        momentary.toggleModuleInput(moduleId: 1, pinIndex: 0)
        #expect(momentary.getNode(id: 1)?.block.outPins.first?.asBool == true)
        momentary.step()
        #expect(momentary.getNode(id: 1)?.block.outPins.first?.asBool == false)
    }

    @Test("A manual interrupt pulse captures its configured value once")
    func manualInterruptPulse() throws {
        let model = model("Main.Execution.Interrupt")
        BlockConfig.apply(["property.SimPulseValue": "42"], to: 1, in: model)
        let core = CxxSimulationCore(project: model.project!, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 0)?.asInt == 0)
        core.fireInterrupt()
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 0)?.asInt == 42)
        #expect(core.outValue(moduleId: 1, pin: 1)?.asBool == true)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 0)?.asInt == 42)
        core.setIn(moduleId: 1, pin: 1, value: .bool(true))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outValue(moduleId: 1, pin: 1)?.asBool == false)
    }

    @Test("CH455G configuration rebuilds its raw-digit pins and parses DIO numbers")
    func displayConfiguration() throws {
        let model = model("IO.CH455G")
        let fields = try #require(BlockConfig.make(of: model, moduleId: 1)).fields
        #expect(fields.contains { $0.key == "property.DisplayMode" })
        #expect(fields.contains { $0.key == "property.DigitMask" && $0.kind == "bits" })
        BlockConfig.apply(["property.DisplayMode": "Raw Digits / Segments", "property.DigitMask": "1010",
                           "property.SclPin": "DIO14", "property.SdaPin": "DIO13"], to: 1, in: model)
        let module = try #require(model.module(id: 1))
        #expect(module.inPins.map(\.name) == ["En", "D0", "D2", "DpMask", "Brt"])
        let compiled = try DuinoCompiler.compile(project: model.project!)
        #expect(compiled.image.indices.contains { index in
            index + 8 <= compiled.image.count && compiled.image[index] == 0x75 && compiled.image[index + 1] == 3
                && compiled.image[index + 6] == 14 && compiled.image[index + 7] == 13
        })
    }

    @Test("CH455G configuration reconnects surviving inputs by name")
    func displayConnectionsFollowPinNames() throws {
        let model = model("IO.CH455G")
        model.project?.inConnections = (0..<4).map {
            Connection(inModuleId: 1, inPinId: $0, outModuleId: 2, outPinId: $0)
        }

        BlockConfig.apply(["property.DisplayMode": "Raw Digits / Segments", "property.DigitMask": "1010"],
                          to: 1, in: model)
        #expect(model.module(id: 1)?.inPins.map(\.name) == ["En", "D0", "D2", "DpMask", "Brt"])
        #expect(model.project?.inConnections.map { [$0.inPinId, $0.outPinId] } == [[0, 0], [4, 3]])

        model.project?.inConnections.append(contentsOf: [
            Connection(inModuleId: 1, inPinId: 2, outModuleId: 2, outPinId: 12),
            Connection(inModuleId: 1, inPinId: 3, outModuleId: 2, outPinId: 13),
        ])
        BlockConfig.apply(["property.DigitMask": "1110"], to: 1, in: model)
        #expect(model.module(id: 1)?.inPins.map(\.name) == ["En", "D0", "D1", "D2", "DpMask", "Brt"])
        #expect(model.project?.inConnections.map { [$0.inPinId, $0.outPinId] } == [[0, 0], [5, 3], [3, 12], [4, 13]])

        BlockConfig.apply(["property.DisplayMode": "Number (Float / Int)"], to: 1, in: model)
        #expect(model.module(id: 1)?.inPins.map(\.name) == ["En", "Val", "Dec", "Brt"])
        #expect(model.project?.inConnections.map { [$0.inPinId, $0.outPinId] } == [[0, 0], [3, 3]])
    }

    @Test("Div's Mod output runs in both engines and disappears with its option")
    func moduloOutputConfiguration() throws {
        let model = model("Math.Div")
        model.project?.modules[0].inPins[1].value = .int32(7)
        model.project?.modules[0].inPins[2].value = .int32(3)
        let config = try #require(BlockConfig.make(of: model, moduleId: 1))
        #expect(config.fields.contains { $0.key == "moduloOut" && $0.kind == "bool" })
        #expect(!config.fields.contains { $0.key == "modulo" })

        BlockConfig.apply(["moduloOut": "1"], to: 1, in: model)
        let enabled = try #require(model.module(id: 1))
        try #require(enabled.outPins.count == 3)
        #expect(enabled.outPins[2].name == "Mod")
        #expect(enabled.rawAttributes["MARAFLOW_PROP_ModuloOut"] == "true")

        let core = CxxSimulationCore(project: model.project!, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: 1)[2].asInt == 1)

        let compiled = try DuinoCompiler.compile(project: model.project!)
        let vm = MaraVM()
        try vm.load(compiled.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.readInt(try #require(compiled.slots["Div1.Mod"])) == 1)
        let exported = String(decoding: try MaraflowExporter.export(model.project!).data, as: UTF8.self)
        #expect(exported.contains("ModuloOut") && exported.contains("out.2.short\">Mod</entry>"))

        BlockConfig.apply(["moduloOut": "0"], to: 1, in: model)
        #expect(model.module(id: 1)?.outPins.count == 2)
        #expect(model.module(id: 1)?.rawAttributes["MARAFLOW_PROP_ModuloOut"] == "false")
    }
}
