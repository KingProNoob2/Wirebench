import SwiftUI
import DirigoCore
import DirigoLibrary
import DirigoEngine

public struct ModuleConfigDialog: View {
    @Bindable var model: AppModel
    let moduleId: Int

    // BoolVar
    @State private var boolVarMode: BoolVarBlock.Mode = .pushButton
    @State private var boolVarInitialState: Bool = false

    // PulseGen & SinglePulse & PulseLength
    @State private var pulseGenTOn: Int = 1
    @State private var pulseGenTOff: Int = 1

    // Counter & AdvCounter
    @State private var counterStep: Int = 1
    @State private var counterMin: Int = 0
    @State private var counterMax: Int = 100
    @State private var counterPreset: Int = 0

    // Timer
    @State private var timerMode: TimerBlock.Mode = .onDelay
    @State private var timerPreset: Int = 10

    // Ramp
    @State private var rampStepUp: Int = 1
    @State private var rampStepDown: Int = 1

    // Limiter
    @State private var limiterMin: Int = 0
    @State private var limiterMax: Int = 100

    // Mean
    @State private var meanWindow: Int = 8

    // Variables (IntVar, FloatVar, LongVar)
    @State private var intVarValue: Int = 0
    @State private var floatVarValue: Double = 0.0

    // Div
    @State private var divModuloVisible: Bool = false

    // RS
    @State private var rsPriorityIsS: Bool = false // false = *R (Reset priority), true = *S (Set priority)

    // DateTime
    @State private var dateTimeShowOffset: Bool = false
    @State private var dateTimeShowSOD: Bool = false

    // 8xPWM
    @State private var pwmSteps: Int = 256

    // Case
    @State private var caseValuesText: String = ""
    /// A switch container's cases, each keeping its id, and whether it has a default branch.
    @State private var switchCases: [ConstructContainers.Case] = []
    @State private var switchHasDefault = true

    // Dynamic Pin Counts (ISwitch, Int2Bits, Logic, Demux)
    @State private var inputCount: Int = 2
    @State private var outputCount: Int = 8

    // 8xDI configuration (PIN_MASK and PIN_ALL_VISIBLE)
    @State private var diMaskBits: [Bool] = Array(repeating: true, count: 16)
    @State private var diShowWordOutput: Bool = false

    // 8xDO configuration (PIN_COUNT and HIDDEN_PIN_MASK)
    @State private var doPinCount: Int = 8
    @State private var doVisibleBits: [Bool] = Array(repeating: true, count: 16)

    // Dynamic Generic Parameters
    @State private var genericParamValues: [Int: String] = [:]

    // Macro interface: a pin name being typed, committed on Return.
    @State private var pinNameDrafts: [Int: String] = [:]

    public init(model: AppModel, moduleId: Int) {
        self.model = model
        self.moduleId = moduleId
    }

    private var targetModule: PCCModule? {
        model.project?.modules.first(where: { $0.id == moduleId })
    }

    private var runtimeNode: RuntimeNode? {
        model.getNode(id: moduleId)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header — same tinted glass language as the inspector hero, so the sheet reads as
            // part of the app rather than a separate window.
            HStack(spacing: 12) {
                let info = targetModule.flatMap { BlockTypeCatalog.info(forGuid: $0.guid) }
                let tint = Theme.tint(forCategory: info?.category ?? "")
                let typeName = targetModule.flatMap { BlockRegistry.shared.resolvedTypeName(for: $0) }

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .frame(width: 38, height: 38)
                    .glassPanel(
                        RoundedRectangle(cornerRadius: 10, style: .continuous),
                        tint: tint,
                        tintOpacity: 0.34
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Configure \(targetModule?.name ?? "Module")")
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let info {
                            Text(info.blockName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(info.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let typeName {
                            Text(typeName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint)
                        }
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Order #\(targetModule?.order ?? 0) · ID \(moduleId)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)

            Divider()

            // Configuration Form Content
            Form {
                if let mod = targetModule {
                    configuration(for: mod)
                }
            }
            .formStyle(.grouped)
            // The grouped `Form` paints its own opaque background; hiding it leaves the sheet's material as the
            // one surface, so header, body and footer are the same colour instead of a lighter panel inset in
            // the middle.
            .scrollContentBackground(.hidden)

            Divider()

            // Footer action buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    model.closeConfigureModule()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applyChanges()
                    model.closeConfigureModule()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 460, height: 420)
        .onAppear {
            loadCurrentValues()
        }
    }

    /// What a module is configured as. The test is on the module's name (a sheet names its blocks freely), in
    /// the order below, which is the order both the form and `applyChanges` rely on.
    private enum Kind {
        case boolVar, pulseGen, singlePulse, counter, advCounter, timer, ramp, range, mean, intVar, floatVar
        case div, rs, dateTime, pwm, caseValues, switchInputs, int2Bits, bits2Int, demux, logic
        case digitalInputs, digitalOutputs, parameters, none
        case macroInterface, macroCall, systemCmd, switchCases

        init(_ mod: PCCModule) {
            // A macro's own blocks are recognised by what they are, not by what the sheet's author named them.
            if MacroInterface.kind(of: mod) != nil { self = .macroInterface; return }
            if MacroCalls.target(of: mod) != nil { self = .macroCall; return }
            if mod.guid == SystemCmdBlock.guid { self = .systemCmd; return }
            if ConstructContainers.isContainer(mod) && mod.guid == ConstructContainers.switchGuid { self = .switchCases; return }
            let n = mod.name.filter { !$0.isNumber }.lowercased()
            func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
            if has("boolvar", "tlacitko", "prepinac", "roztoct") || mod.guid == BoolVarBlock.guid { self = .boolVar }
            else if has("pulsegen") { self = .pulseGen }
            else if has("singlepulse", "pulselen") { self = .singlePulse }
            else if n.contains("counter") && !n.contains("adv") { self = .counter }
            else if n.contains("advcounter") || n == "cnt" { self = .advCounter }
            else if has("timer") { self = .timer }
            else if has("ramp") { self = .ramp }
            else if has("limiter", "inrange") { self = .range }
            else if has("mean") { self = .mean }
            else if has("intvar", "longvar") { self = .intVar }
            else if has("floatvar") { self = .floatVar }
            else if n.contains("div") && !n.contains("fdiv") { self = .div }
            else if n == "rs" { self = .rs }
            else if has("datetime") { self = .dateTime }
            else if has("8xpwm") || n == "pwm" { self = .pwm }
            else if has("case") { self = .caseValues }
            else if n.contains("switch") && !n.contains("end") { self = .switchInputs }
            else if has("intbits", "int2bits") { self = .int2Bits }
            else if has("bitsint", "bits2int") { self = .bits2Int }
            else if has("demux") { self = .demux }
            else if n == "and" || n == "or" || n.contains("orspin") || n == "xor" || n == "copy" { self = .logic }
            else if has("xdi", "8xdi", "digitalinput") { self = .digitalInputs }
            else if has("xdo", "8xdo", "digitaloutput") { self = .digitalOutputs }
            else { self = mod.paramPins.isEmpty ? .none : .parameters }
        }
    }

    /// A line of explanation under a control.
    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func configuration(for mod: PCCModule) -> some View {
        switch Kind(mod) {
        case .boolVar:
            Section("Simulation Mode & Behavior") {
                Picker("Control Type:", selection: $boolVarMode) {
                    Text("Push Button (Momentary Pulse)").tag(BoolVarBlock.Mode.pushButton)
                    Text("Button that stays set (Toggle / Latch)").tag(BoolVarBlock.Mode.toggleSwitch)
                    Text("Slider / Direct Switch").tag(BoolVarBlock.Mode.slider)
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 4)

                Toggle("Initial State (1 = HIGH / ON)", isOn: $boolVarInitialState)
                    .padding(.top, 4)

                hint(modeExplanation(boolVarMode))
                    .padding(.top, 2)
            }
        case .pulseGen:
            Section("Pulse Generator Timing") {
                Stepper("Time On (TOn cycles): \(pulseGenTOn)", value: $pulseGenTOn, in: 1...10000)
                Stepper("Time Off (TOff cycles): \(pulseGenTOff)", value: $pulseGenTOff, in: 1...10000)
                hint("Oscillator stays HIGH for \(pulseGenTOn) tick(s) and LOW for \(pulseGenTOff) tick(s).")
            }
        case .singlePulse:
            Section("Pulse Length Timing") {
                Stepper("Pulse Duration (TOn cycles): \(pulseGenTOn)", value: $pulseGenTOn, in: 1...10000)
                hint("Generates a single pulse of duration \(pulseGenTOn) tick(s) upon trigger.")
            }
        case .counter:
            Section("Counter Configuration") {
                Stepper("Step Value (St): \(counterStep)", value: $counterStep, in: -1000...1000)
                hint("Amount incremented or decremented on each rising trigger pulse.")
            }
        case .advCounter:
            Section("Advanced Counter Limits & Step") {
                Stepper("Step Value (St): \(counterStep)", value: $counterStep, in: -1000...1000)
                Stepper("Preset Value (PV): \(counterPreset)", value: $counterPreset, in: -10000...10000)
                Stepper("Minimum Limit (Min): \(counterMin)", value: $counterMin, in: -10000...10000)
                Stepper("Maximum Limit (Max): \(counterMax)", value: $counterMax, in: -10000...10000)
            }
        case .timer:
            Section("Timer Mode & Duration") {
                Picker("Timer Type:", selection: $timerMode) {
                    Text("On-Delay (TON)").tag(TimerBlock.Mode.onDelay)
                    Text("Continuous On-Delay").tag(TimerBlock.Mode.onDelayContinuous)
                    Text("Fixed Pulse (TP)").tag(TimerBlock.Mode.fixedPulse)
                    Text("Truncated Pulse").tag(TimerBlock.Mode.truncatedPulse)
                }
                Stepper("Preset Time (PT ticks): \(timerPreset)", value: $timerPreset, in: 1...100000)
            }
        case .ramp:
            Section("Ramp Slope Speeds") {
                Stepper("Step Up (SU per cycle): \(rampStepUp)", value: $rampStepUp, in: 1...10000)
                Stepper("Step Down (SD per cycle): \(rampStepDown)", value: $rampStepDown, in: 1...10000)
            }
        case .range:
            Section("Range Bounds") {
                Stepper("Minimum Limit: \(limiterMin)", value: $limiterMin, in: -100000...100000)
                Stepper("Maximum Limit: \(limiterMax)", value: $limiterMax, in: -100000...100000)
            }
        case .mean:
            Section("Filter Window") {
                Stepper("Sample Window Size: \(meanWindow)", value: $meanWindow, in: 1...128)
                hint("Computes running average over the last \(meanWindow) samples.")
            }
        case .intVar:
            Section("Initial Variable Value") {
                TextField("Initial Value", value: $intVarValue, format: .number)
            }
        case .floatVar:
            Section("Initial Variable Value") {
                TextField("Initial Value", value: $floatVarValue, format: .number)
            }
        case .div:
            Section("Division Options") {
                Toggle("Show Modulo Output Pin (Mod = A % B)", isOn: $divModuloVisible)
                hint("When checked, activates the optional 'Mod' remainder output pin on the module.")
            }
        case .rs:
            Section("Simultaneous Input Priority") {
                Picker("When both S and R are 1:", selection: $rsPriorityIsS) {
                    Text("Higher priority of input R  (*R) — Reset dominant").tag(false)
                    Text("Higher priority of input S  (*S) — Set dominant").tag(true)
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 4)

                hint(rsPriorityIsS ? "Set Dominant: if S=1 and R=1, output Y remains 1."
                                   : "Reset Dominant: if S=1 and R=1, output Y is reset to 0.")
            }
        case .dateTime:
            Section("Optional Pins") {
                Toggle("Input Pin Offset (Offs in seconds)", isOn: $dateTimeShowOffset)
                Toggle("Output Pin SOD (Second of Day: 0..86399)", isOn: $dateTimeShowSOD)
            }
        case .pwm:
            Section("PWM Configuration") {
                Stepper("PWM Step Count (N): \(pwmSteps)", value: $pwmSteps, in: 2...65536)
                hint("Standard value is 256 steps. Operating range of analog inputs AO0..AO7 is 0 to N.")
            }
        case .switchCases:
            Section("Cases") {
                // Rows are keyed by case id, not position: index-bound rows crash SwiftUI when one is removed.
                ForEach($switchCases, id: \.id) { $item in
                    HStack {
                        TextField("Values (e.g. 1, 5..7, 9)", text: $item.values)
                            .font(.system(.body, design: .monospaced))
                        Text(memberCountLabel(arm: item.id))
                            .font(.caption).foregroundStyle(.secondary)
                        Button { moveCase(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(switchCases.first?.id == item.id)
                        Button { moveCase(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(switchCases.last?.id == item.id)
                        Button(role: .destructive) { switchCases.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Button("Add Case", systemImage: "plus") {
                    switchCases.append(.init(id: ConstructContainers.newCaseId(among: switchCases), values: ""))
                }
                .buttonStyle(.borderless)
                Toggle("Default branch", isOn: $switchHasDefault)
                hint("Blocks are put into a case from their right-click menu. Blocks of a removed case move to the default branch, or out of the switch if there is none.")
            }
        case .caseValues:
            Section("Case Values & Ranges") {
                TextField("Values (e.g. 1, 5..7, 9)", text: $caseValuesText)
                hint("Define one or more values or consecutive ranges (e.g. 1, 5..7, 9).")
            }
        case .switchInputs:
            Section("Switch Configuration") {
                Stepper("Number of Inputs (X0..Xn): \(inputCount)", value: $inputCount, in: 1...16)
                hint("Original Dirigo ISwitch allows 1 to 16 configurable input value lines.")
            }
        case .int2Bits:
            Section("Int2Bits Configuration") {
                Stepper("Number of Output Bits (B0..Bn): \(outputCount)", value: $outputCount, in: 1...16)
                hint("Original Dirigo Int2Bits allows extracting 1 to 16 individual bits from integer input X.")
            }
        case .bits2Int:
            Section("Bits2Int Configuration") {
                Stepper("Number of Input Bits (B0..Bn): \(inputCount)", value: $inputCount, in: 1...16)
            }
        case .demux:
            Section("Demultiplexer Configuration") {
                Stepper("Number of Outputs (Y0..Yn): \(outputCount)", value: $outputCount, in: 1...126)
                hint("Directs input X to output Y[Idx]. Configurable range: 1 to 126 outputs.")
            }
        case .logic:
            Section("Logic Input Count") {
                Stepper("Number of Inputs (X0..Xn): \(inputCount)", value: $inputCount, in: 1...16)
                hint("Configurable input operands for \(mod.name). Range: 1 to 16 inputs.")
            }
        case .digitalInputs:
            Section("Select Visible Pins") {
                hint("Select which digital input pins (DI0..DI15) are exposed:")

                channelGrid(prefix: "DI", count: 16, bits: $diMaskBits)

                Divider()

                Toggle("Word Output (All - 16-bit integer)", isOn: $diShowWordOutput)
                    .toggleStyle(.checkbox)
            }
        case .digitalOutputs:
            Section("Digital Outputs Configuration") {
                Stepper("Pin Count: \(doPinCount)", value: $doPinCount, in: 1...32)

                hint("Visible output channels:")
                    .padding(.top, 2)

                channelGrid(prefix: "DO", count: min(doPinCount, 16), bits: $doVisibleBits)
            }
        case .parameters:
            Section("Block Parameters") {
                ForEach(0..<mod.paramPins.count, id: \.self) { idx in
                    HStack {
                        Text(ModulePinCatalog.paramPinFullName(for: mod, index: idx))
                        Spacer()
                        TextField("Value", text: Binding(
                            get: { genericParamValues[idx] ?? mod.paramPins[idx].value.description },
                            set: { genericParamValues[idx] = $0 }
                        ))
                        .frame(width: 120)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        case .none:
            Section("Information") {
                Text("This function block does not have configurable simulation parameters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .macroInterface:
            let isInputs = MacroInterface.kind(of: mod) == .inputs
            Section(isInputs ? "Macro Inputs" : "Macro Outputs") {
                ForEach(Array(MacroInterface.pinNames(of: mod).enumerated()), id: \.offset) { index, name in
                    HStack {
                        TextField("Pin name", text: Binding(
                            get: { pinNameDrafts[index] ?? name },
                            set: { pinNameDrafts[index] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let draft = pinNameDrafts[index] {
                                model.renameInterfacePin(moduleId: moduleId, pin: index, to: draft)
                                pinNameDrafts[index] = nil
                            }
                        }
                        Button {
                            pinNameDrafts = [:]
                            model.removeInterfacePin(moduleId: moduleId, pin: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this pin")
                        .disabled(MacroInterface.pinNames(of: mod).count <= 1)
                    }
                }
                Button {
                    model.addInterfacePin(moduleId: moduleId)
                } label: {
                    Label("Add Pin", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                hint("Every call of this macro gets the same pins. Names are saved when you press Return.")
            }
        case .systemCmd:
            Section("System Command") {
                let catalogue = model.systemCommandCatalogue
                let current = model.systemCommand(of: mod)
                // A command the project uses but the profile does not list (`zelznice.pcc`'s `Pwm` on a P3) stays selectable.
                let options = current.map { c in catalogue.contains { $0.command == c.command && $0.text == c.text } ? catalogue : [c] + catalogue } ?? catalogue
                Picker("Command", selection: Binding<String>(
                    get: { current?.selectionTag ?? "" },
                    set: { tag in
                        model.setSystemCommand(moduleId: moduleId,
                                               to: catalogue.first { $0.selectionTag == tag })
                    }
                )) {
                    Text("None — set the command word on the Cmd pin").tag("")
                    ForEach(options, id: \.mnemonic) { info in
                        Text("\(info.title)  ·  \(info.text)").tag(info.selectionTag)
                    }
                }
                if let current {
                    LabeledContent("Command word", value: String(format: "0x%04X", current.command))
                    LabeledContent("Parameter 1", value: current.input1.isHidden ? "not used" : "\(current.input1.name) (\(current.input1.dataType))")
                    LabeledContent("Parameter 2", value: current.input2.isHidden ? "not used" : "\(current.input2.name) (\(current.input2.dataType))")
                    LabeledContent("Result", value: current.output.isHidden ? "not used" : "\(current.output.name) (\(current.output.dataType))")
                }
                ForEach(0..<mod.paramPins.count, id: \.self) { index in
                    LabeledContent(ModulePinCatalog.paramPinFullName(for: mod, index: index)) {
                        ParamValueField(model: model, moduleId: moduleId, index: index,
                                        current: mod.paramPins[index].value.description)
                    }
                }
                hint("The pins are named after the command, and only the ones it uses are written to the PLC.")
            }
        case .macroCall:
            Section("Macro Call") {
                if let name = MacroCalls.target(of: mod) {
                    LabeledContent("Calls", value: "*" + name)
                    Button {
                        model.selectedPage = "*" + name
                        model.closeConfigureModule()
                    } label: {
                        Label("Open Macro", systemImage: "arrow.up.right.square")
                    }
                    hint("The pins follow the macro's Inputs and Outputs blocks.")
                }
            }
        }
    }

    /// A grid of one checkbox per channel (`DI0`, `DO3`, …).
    private func channelGrid(prefix: String, count: Int, bits: Binding<[Bool]>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
            ForEach(0..<count, id: \.self) { bit in
                Toggle("\(prefix)\(bit)", isOn: bits[bit])
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 4)
    }

    private func modeExplanation(_ mode: BoolVarBlock.Mode) -> String {
        switch mode {
        case .pushButton:
            return "Emits a momentary HIGH pulse when pressed, then automatically drops back to 0."
        case .toggleSwitch:
            return "Stays set in its new state (1 or 0) on every click like a toggle latch."
        case .slider:
            return "Acts as a continuous simulation slider/switch control."
        }
    }

    private func loadCurrentValues() {
        guard let mod = targetModule else { return }

        // The block's type, and its live pins where the simulation holds a value the document does not.
        let live = runtimeNode?.block
        let params = live?.paramPins ?? mod.paramPins.map(\.value)
        let delphiClass = BlockRole.delphiClass(of: mod) ?? ""

        // BoolVar
        if let mode = BlockRole.boolVarMode(of: mod) {
            self.boolVarMode = mode
            self.boolVarInitialState = live?.outPins.first?.asBool ?? false
        }

        // PulseGen & SinglePulse & PulseLength
        switch delphiClass {
        case "TMPulseGenerator":
            if params.count > 0 { self.pulseGenTOn = max(1, params[0].asInt) }
            if params.count > 1 { self.pulseGenTOff = max(1, params[1].asInt) }
        case "TMSinglePulse", "TMPulseLength":
            if params.count > 0 { self.pulseGenTOn = max(1, params[0].asInt) }
        default:
            if mod.paramPins.count > 0 { self.pulseGenTOn = max(1, mod.paramPins[0].value.asInt) }
            if mod.paramPins.count > 1 { self.pulseGenTOff = max(1, mod.paramPins[1].value.asInt) }
        }

        // Counter & AdvCounter
        switch delphiClass {
        case "TMCounter":
            if params.count > 0 { self.counterStep = params[0].asInt }
        case "TMAdvCounter":
            if params.count > 0 { self.counterPreset = params[0].asInt }
            if params.count > 1 { self.counterMax = params[1].asInt }
            if params.count > 2 { self.counterMin = params[2].asInt }
            if params.count > 3 { self.counterStep = params[3].asInt }
        default:
            if mod.paramPins.count >= 1 { self.counterStep = mod.paramPins[0].value.asInt }
        }

        // Timer: the mode is the module's `MODE` attribute, as the registry reads it.
        if delphiClass == "TMTimer" {
            self.timerMode = TimerBlock.Mode(rawValue: Int(mod.rawAttributes["MODE"] ?? "0") ?? 0) ?? .onDelay
            if params.count > 0 { self.timerPreset = max(1, params[0].asInt) }
        }

        // Ramp
        if mod.paramPins.count >= 2 {
            self.rampStepUp = max(1, mod.paramPins[0].value.asInt)
            self.rampStepDown = max(1, mod.paramPins[1].value.asInt)
        }

        // Limiter
        if mod.paramPins.count >= 2 {
            self.limiterMin = mod.paramPins[0].value.asInt
            self.limiterMax = mod.paramPins[1].value.asInt
        }

        // Mean
        if delphiClass == "TMMean", params.count > 0 {
            self.meanWindow = max(1, params[0].asInt)
        }

        // Variables: the value is the variable's output.
        if BlockRole.isIntVariable(mod), let value = live?.outPins.first {
            self.intVarValue = value.asInt
        }
        if BlockRole.isFloatVariable(mod), let value = live?.outPins.first {
            self.floatVarValue = Double(value.asFloat)
        }

        // Div Modulo
        self.divModuloVisible = mod.rawAttributes["MODULO_VISIBLE"]?.lowercased() == "true" || mod.rawAttributes["SHOW_MODULO"]?.lowercased() == "true" || (mod.outPins.count > 1)

        // RS Priority
        self.rsPriorityIsS = (mod.rawAttributes["PRIORITY"]?.uppercased() == "S") || (mod.rawAttributes["RS_PRIORITY"]?.uppercased() == "S")

        // DateTime
        self.dateTimeShowOffset = mod.rawAttributes["SHOW_OFFSET"]?.lowercased() == "true" || mod.rawAttributes["OFFSET_VISIBLE"]?.lowercased() == "true"
        self.dateTimeShowSOD = mod.rawAttributes["SHOW_SOD"]?.lowercased() == "true" || mod.rawAttributes["SOD_VISIBLE"]?.lowercased() == "true"

        // 8xPWM
        if delphiClass == "TMPWMOutputs" {
            // As the registry configures the block: a legacy param pin, else `PWM_STEPS`, else 256.
            self.pwmSteps = max(2, mod.paramPins.first?.value.asInt
                ?? mod.rawAttributes["PWM_STEPS"].flatMap { Int($0) } ?? 256)
        } else if let s = mod.paramPins.first?.value.asInt {
            self.pwmSteps = s
        } else if let sStr = mod.rawAttributes["PWM_STEPS"], let s = Int(sStr) {
            self.pwmSteps = s
        }

        // Switch container
        self.switchCases = ConstructContainers.cases(of: mod)
        self.switchHasDefault = mod.rawAttributes["DEFAULT"] == "1"

        // Case
        self.caseValuesText = mod.rawAttributes["VALUES"] ?? mod.rawAttributes["CASE_VALUES"] ?? ""

        // Dynamic pin counts (ISwitch, Int2Bits, Logic, Demux)
        if let inStr = mod.rawAttributes["INPUT_COUNT"], let c = Int(inStr) {
            self.inputCount = c
        } else if mod.name.lowercased().contains("switch") {
            self.inputCount = max(mod.inPins.count - 2, 2)
        } else if mod.name.lowercased().contains("bits2int") || mod.name.lowercased().contains("bitsint") {
            self.inputCount = max(mod.inPins.count, 8)
        } else {
            self.inputCount = max(mod.inPins.count - 1, 2)
        }

        if let outStr = mod.rawAttributes["OUTPUT_COUNT"], let c = Int(outStr) {
            self.outputCount = c
        } else if mod.name.lowercased().contains("int2bits") || mod.name.lowercased().contains("intbits") {
            self.outputCount = max(mod.outPins.count, 8)
        } else if mod.name.lowercased().contains("demux") {
            self.outputCount = max(mod.outPins.count, 4)
        } else {
            self.outputCount = max(mod.outPins.count, 8)
        }

        // 8xDI PIN_MASK & Word Output
        let diMaskVal: Int = {
            if let raw = mod.rawAttributes["PIN_MASK"] {
                return PinMask.parse(raw)
            }
            return 0xFF
        }()
        for bit in 0..<16 {
            self.diMaskBits[bit] = (diMaskVal & (1 << bit)) != 0
        }
        self.diShowWordOutput = mod.rawAttributes["PIN_ALL_VISIBLE"]?.lowercased() == "true"

        // 8xDO PIN_COUNT & HIDDEN_PIN_MASK
        self.doPinCount = mod.rawAttributes["PIN_COUNT"].flatMap { Int($0) } ?? max(mod.inPins.count, 8)
        let doHiddenMask: Int = {
            if let raw = mod.rawAttributes["HIDDEN_PIN_MASK"] {
                return PinMask.parse(raw)
            }
            return 0
        }()
        for bit in 0..<16 {
            self.doVisibleBits[bit] = (doHiddenMask & (1 << bit)) == 0
        }

        // Generic params map
        for (i, p) in mod.paramPins.enumerated() {
            genericParamValues[i] = p.value.description
        }
    }

    private func moveCase(_ id: String, by offset: Int) {
        guard let i = switchCases.firstIndex(where: { $0.id == id }),
              switchCases.indices.contains(i + offset) else { return }
        switchCases.swapAt(i, i + offset)
    }

    /// "2 blocks" for the blocks in one case of the switch being edited; empty when there are none.
    private func memberCountLabel(arm: String) -> String {
        let count = model.project?.modules.filter {
            $0.rawAttributes["IN_CONTAINER"] == "\(moduleId)" && $0.rawAttributes["ARM"] == arm
        }.count ?? 0
        return count == 0 ? "" : count == 1 ? "1 block" : "\(count) blocks"
    }

    private func applyChanges() {
        guard let mod = targetModule else { return }
        func setParam(_ index: Int, _ value: Int) {
            model.updateModuleParam(id: moduleId, paramIndex: index, value: .int32(Int32(value)))
        }
        func showAttribute(_ keys: [String], _ on: Bool) {
            for key in keys { model.setModuleRawAttribute(id: moduleId, key: key, value: on ? "True" : "False") }
        }
        /// A mask word with a bit set for every channel the grid has in `state`.
        func mask(_ bits: [Bool], count: Int, where state: Bool) -> String {
            let word = (0..<min(count, 16)).reduce(0) { $0 | (bits[$1] == state ? 1 << $1 : 0) }
            return String(format: "$%04X", word)
        }

        switch Kind(mod) {
        case .boolVar:
            model.updateBoolVarMode(id: moduleId, mode: boolVarMode)
            model.setModuleOutput(moduleId: moduleId, pinIndex: 0, value: .bool(boolVarInitialState))
        case .pulseGen:
            model.updatePulseGenTiming(id: moduleId, tOn: pulseGenTOn, tOff: pulseGenTOff)
        case .singlePulse:
            setParam(0, pulseGenTOn)
        case .counter:
            model.updateCounterStep(id: moduleId, step: counterStep)
        case .advCounter:
            setParam(0, counterPreset)
            setParam(1, counterMax)
            setParam(2, counterMin)
            setParam(3, counterStep)
        case .timer:
            // Stored on the module, where the core and a reopened file both read it.
            model.setModuleRawAttribute(id: moduleId, key: "MODE", value: "\(timerMode.rawValue)")
            model.reconfigureModule(id: moduleId)
            setParam(0, timerPreset)
        case .ramp:
            setParam(0, rampStepUp)
            setParam(1, rampStepDown)
        case .range:
            setParam(0, limiterMin)
            setParam(1, limiterMax)
        case .mean:
            setParam(0, meanWindow)
        case .intVar:
            // `IntVar` has no parameters — the help gives it a single output — so the initial
            // value is stored as an attribute and pushed into the live block.
            model.setModuleRawAttribute(id: moduleId, key: "INIT_VALUE", value: "\(intVarValue)")
            model.setVariableValue(moduleId: moduleId, value: intVarValue)
        case .floatVar:
            model.setModuleRawAttribute(id: moduleId, key: "INIT_VALUE", value: "\(floatVarValue)")
            model.setFloatVariableValue(moduleId: moduleId, value: Float(floatVarValue))
        case .div:
            model.updateDivModuloVisible(id: moduleId, isVisible: divModuloVisible)
        case .rs:
            model.updateRSPriority(id: moduleId, higherPriorityS: rsPriorityIsS)
        case .dateTime:
            showAttribute(["SHOW_OFFSET", "OFFSET_VISIBLE"], dateTimeShowOffset)
            showAttribute(["SHOW_SOD", "SOD_VISIBLE"], dateTimeShowSOD)
        case .pwm:
            setParam(0, pwmSteps)
            model.setModuleRawAttribute(id: moduleId, key: "PWM_STEPS", value: "\(pwmSteps)")
        case .switchCases:
            // `|` and `:` are the format's separators, never part of a value list. A case left empty is removed.
            let cases = switchCases.map { item -> ConstructContainers.Case in
                var clean = item
                clean.values = item.values.filter { $0 != "|" && $0 != ":" }.trimmingCharacters(in: .whitespaces)
                return clean
            }.filter { !$0.values.isEmpty }
            model.setSwitchCases(of: moduleId, to: cases, hasDefault: switchHasDefault)
        case .caseValues:
            model.setModuleRawAttribute(id: moduleId, key: "VALUES", value: caseValuesText)
        case .switchInputs, .bits2Int, .logic:
            model.updateModuleInputCount(id: moduleId, count: inputCount)
        case .int2Bits, .demux:
            model.updateModuleOutputCount(id: moduleId, count: outputCount)
        case .digitalInputs:
            model.update8xDIMask(id: moduleId, maskHex: mask(diMaskBits, count: 16, where: true),
                                 showWord: diShowWordOutput)
        case .digitalOutputs:
            model.update8xDOConfig(id: moduleId, pinCount: doPinCount,
                                   hiddenMaskHex: mask(doVisibleBits, count: doPinCount, where: false))
        case .macroInterface, .macroCall:
            break
        case .parameters, .none, .systemCmd:
            for (index, text) in genericParamValues {
                model.updateModuleParam(id: moduleId, paramIndex: index, value: PinValue.parse(text))
            }
        }
    }
}
