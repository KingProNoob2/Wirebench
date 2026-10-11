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

    public init(model: AppModel, moduleId: Int) {
        self.model = model
        self.moduleId = moduleId
    }

    private var targetModule: PCCModule? {
        model.project?.modules.first(where: { $0.id == moduleId })
    }

    private var runtimeNode: SimulationEngine.RuntimeNode? {
        model.getNode(id: moduleId)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header — same tinted glass language as the inspector hero, so the sheet reads as
            // part of the app rather than a separate window.
            HStack(spacing: 12) {
                let info = targetModule.flatMap { BlockTypeCatalog.info(forGuid: $0.guid) }
                let tint = Theme.tint(forCategory: info?.category ?? "")
                let typeName = targetModule.flatMap { model.getNode(id: $0.id).map { type(of: $0.block).typeName } }

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
            .background(.thinMaterial)

            Divider()

            // Configuration Form Content
            Form {
                if let mod = targetModule {
                    let cleanName = mod.name.filter { !$0.isNumber }.lowercased()

                    // 1. BoolVar Configuration
                    if cleanName.contains("boolvar") || cleanName.contains("tlacitko") || cleanName.contains("prepinac") || cleanName.contains("roztoct") || mod.guid == BoolVarBlock.guid {
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

                            Text(modeExplanation(boolVarMode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }

                    // 2. PulseGen Configuration
                    else if cleanName.contains("pulsegen") {
                        Section("Pulse Generator Timing") {
                            Stepper("Time On (TOn cycles): \(pulseGenTOn)", value: $pulseGenTOn, in: 1...10000)
                            Stepper("Time Off (TOff cycles): \(pulseGenTOff)", value: $pulseGenTOff, in: 1...10000)
                            Text("Oscillator stays HIGH for \(pulseGenTOn) tick(s) and LOW for \(pulseGenTOff) tick(s).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 3. SinglePulse / PulseLength
                    else if cleanName.contains("singlepulse") || cleanName.contains("pulselen") {
                        Section("Pulse Length Timing") {
                            Stepper("Pulse Duration (TOn cycles): \(pulseGenTOn)", value: $pulseGenTOn, in: 1...10000)
                            Text("Generates a single pulse of duration \(pulseGenTOn) tick(s) upon trigger.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 4. Counter Configuration
                    else if cleanName.contains("counter") && !cleanName.contains("adv") {
                        Section("Counter Configuration") {
                            Stepper("Step Value (St): \(counterStep)", value: $counterStep, in: -1000...1000)
                            Text("Amount incremented or decremented on each rising trigger pulse.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 5. AdvCounter Configuration
                    else if cleanName.contains("advcounter") || cleanName == "cnt" {
                        Section("Advanced Counter Limits & Step") {
                            Stepper("Step Value (St): \(counterStep)", value: $counterStep, in: -1000...1000)
                            Stepper("Preset Value (PV): \(counterPreset)", value: $counterPreset, in: -10000...10000)
                            Stepper("Minimum Limit (Min): \(counterMin)", value: $counterMin, in: -10000...10000)
                            Stepper("Maximum Limit (Max): \(counterMax)", value: $counterMax, in: -10000...10000)
                        }
                    }

                    // 6. Timer Configuration
                    else if cleanName.contains("timer") {
                        Section("Timer Mode & Duration") {
                            Picker("Timer Type:", selection: $timerMode) {
                                Text("On-Delay (TON)").tag(TimerBlock.Mode.onDelay)
                                Text("Continuous On-Delay").tag(TimerBlock.Mode.onDelayContinuous)
                                Text("Fixed Pulse (TP)").tag(TimerBlock.Mode.fixedPulse)
                                Text("Truncated Pulse").tag(TimerBlock.Mode.truncatedPulse)
                            }
                            Stepper("Preset Time (PT ticks): \(timerPreset)", value: $timerPreset, in: 1...100000)
                        }
                    }

                    // 7. Ramp Configuration
                    else if cleanName.contains("ramp") {
                        Section("Ramp Slope Speeds") {
                            Stepper("Step Up (SU per cycle): \(rampStepUp)", value: $rampStepUp, in: 1...10000)
                            Stepper("Step Down (SD per cycle): \(rampStepDown)", value: $rampStepDown, in: 1...10000)
                        }
                    }

                    // 8. Limiter / InRange Configuration
                    else if cleanName.contains("limiter") || cleanName.contains("inrange") {
                        Section("Range Bounds") {
                            Stepper("Minimum Limit: \(limiterMin)", value: $limiterMin, in: -100000...100000)
                            Stepper("Maximum Limit: \(limiterMax)", value: $limiterMax, in: -100000...100000)
                        }
                    }

                    // 9. Mean (Moving Average) Filter
                    else if cleanName.contains("mean") {
                        Section("Filter Window") {
                            Stepper("Sample Window Size: \(meanWindow)", value: $meanWindow, in: 1...128)
                            Text("Computes running average over the last \(meanWindow) samples.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 10. IntVar / LongVar / FloatVar
                    else if cleanName.contains("intvar") || cleanName.contains("longvar") {
                        Section("Initial Variable Value") {
                            TextField("Initial Value", value: $intVarValue, format: .number)
                        }
                    } else if cleanName.contains("floatvar") {
                        Section("Initial Variable Value") {
                            TextField("Initial Value", value: $floatVarValue, format: .number)
                        }
                    }

                    // 11. Div Configuration (Modulo remainder output toggle)
                    else if cleanName.contains("div") && !cleanName.contains("fdiv") {
                        Section("Division Options") {
                            Toggle("Show Modulo Output Pin (Mod = A % B)", isOn: $divModuloVisible)
                            Text("When checked, activates the optional 'Mod' remainder output pin on the module.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 12. RS Flip-Flop Configuration (Priority selection)
                    else if cleanName == "rs" {
                        Section("Simultaneous Input Priority") {
                            Picker("When both S and R are 1:", selection: $rsPriorityIsS) {
                                Text("Higher priority of input R  (*R) — Reset dominant").tag(false)
                                Text("Higher priority of input S  (*S) — Set dominant").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .padding(.vertical, 4)

                            Text(rsPriorityIsS ? "Set Dominant: if S=1 and R=1, output Y remains 1." : "Reset Dominant: if S=1 and R=1, output Y is reset to 0.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 13. DateTime Configuration (Offset and SecondOfDay pins)
                    else if cleanName.contains("datetime") {
                        Section("Optional Pins") {
                            Toggle("Input Pin Offset (Offs in seconds)", isOn: $dateTimeShowOffset)
                            Toggle("Output Pin SOD (Second of Day: 0..86399)", isOn: $dateTimeShowSOD)
                        }
                    }

                    // 14. 8xPWM Configuration (Steps / Frequency)
                    else if cleanName.contains("8xpwm") || cleanName == "pwm" {
                        Section("PWM Configuration") {
                            Stepper("PWM Step Count (N): \(pwmSteps)", value: $pwmSteps, in: 2...65536)
                            Text("Standard value is 256 steps. Operating range of analog inputs AO0..AO7 is 0 to N.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 15. Case Statement Configuration
                    else if cleanName.contains("case") {
                        Section("Case Values & Ranges") {
                            TextField("Values (e.g. 1, 5..7, 9)", text: $caseValuesText)
                            Text("Define one or more values or consecutive ranges (e.g. 1, 5..7, 9).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 16. ISwitch / LSwitch / FSwitch Configuration (1 to 16 inputs)
                    else if cleanName.contains("switch") && !cleanName.contains("end") {
                        Section("Switch Configuration") {
                            Stepper("Number of Inputs (X0..Xn): \(inputCount)", value: $inputCount, in: 1...16)
                            Text("Original Dirigo ISwitch allows 1 to 16 configurable input value lines.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 17. Int2Bits Configuration (1 to 16 output bits)
                    else if cleanName.contains("intbits") || cleanName.contains("int2bits") {
                        Section("Int2Bits Configuration") {
                            Stepper("Number of Output Bits (B0..Bn): \(outputCount)", value: $outputCount, in: 1...16)
                            Text("Original Dirigo Int2Bits allows extracting 1 to 16 individual bits from integer input X.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 18. Bits2Int Configuration (1 to 16 input bits)
                    else if cleanName.contains("bitsint") || cleanName.contains("bits2int") {
                        Section("Bits2Int Configuration") {
                            Stepper("Number of Input Bits (B0..Bn): \(inputCount)", value: $inputCount, in: 1...16)
                        }
                    }

                    // 19. IDemux / FDemux / LDemux Configuration (1 to 126 outputs)
                    else if cleanName.contains("demux") {
                        Section("Demultiplexer Configuration") {
                            Stepper("Number of Outputs (Y0..Yn): \(outputCount)", value: $outputCount, in: 1...126)
                            Text("Directs input X to output Y[Idx]. Configurable range: 1 to 126 outputs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 20. Logic gates (And, Or, Xor, Copy)
                    else if cleanName == "and" || cleanName == "or" || cleanName.contains("orspin") || cleanName == "xor" || cleanName == "copy" {
                        Section("Logic Input Count") {
                            Stepper("Number of Inputs (X0..Xn): \(inputCount)", value: $inputCount, in: 1...16)
                            Text("Configurable input operands for \(mod.name). Range: 1 to 16 inputs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 21. 8xDI Configuration (Digital Inputs Mask & Word output)
                    else if cleanName.contains("xdi") || cleanName.contains("8xdi") || cleanName.contains("digitalinput") {
                        Section("Select Visible Pins") {
                            Text("Select which digital input pins (DI0..DI15) are exposed:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                                ForEach(0..<16, id: \.self) { bit in
                                    Toggle("DI\(bit)", isOn: $diMaskBits[bit])
                                        .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.vertical, 4)

                            Divider()

                            Toggle("Word Output (All - 16-bit integer)", isOn: $diShowWordOutput)
                                .toggleStyle(.checkbox)
                        }
                    }

                    // 22. 8xDO Configuration (Digital Outputs Count & Mask)
                    else if cleanName.contains("xdo") || cleanName.contains("8xdo") || cleanName.contains("digitaloutput") {
                        Section("Digital Outputs Configuration") {
                            Stepper("Pin Count: \(doPinCount)", value: $doPinCount, in: 1...32)

                            Text("Visible output channels:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                                ForEach(0..<min(doPinCount, 16), id: \.self) { bit in
                                    Toggle("DO\(bit)", isOn: $doVisibleBits[bit])
                                        .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Generic Parameters for all other function blocks with parameters
                    else if !mod.paramPins.isEmpty {
                        Section("Block Parameters") {
                            ForEach(0..<mod.paramPins.count, id: \.self) { idx in
                                let pName = ModulePinCatalog.paramPinFullName(for: mod, index: idx)
                                HStack {
                                    Text(pName)
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
                    } else {
                        Section("Information") {
                            Text("This function block does not have configurable simulation parameters.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // `Form` in its grouped style paints the system's opaque background, which reads as a
            // grey slab sitting inside the dialog's translucent chrome. Let the material through
            // instead, so header, body and footer are one surface.
            .scrollContentBackground(.hidden)
            .background(.thinMaterial)
            .padding(.horizontal, 12)
            .padding(.top, 8)

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
            .background(.thinMaterial)
        }
        .frame(width: 460, height: 420)
        .onAppear {
            loadCurrentValues()
        }
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

        // BoolVar
        if let boolVar = runtimeNode?.block as? BoolVarBlock {
            self.boolVarMode = boolVar.mode
            self.boolVarInitialState = boolVar.outPins.first?.asBool ?? false
        } else if let simulMode = mod.simulMode {
            self.boolVarMode = BoolVarBlock.Mode(rawValue: simulMode) ?? .pushButton
        }

        // PulseGen & SinglePulse & PulseLength
        if let pulseGen = runtimeNode?.block as? PulseGenBlock {
            if pulseGen.paramPins.count > 0 { self.pulseGenTOn = max(1, pulseGen.paramPins[0].asInt) }
            if pulseGen.paramPins.count > 1 { self.pulseGenTOff = max(1, pulseGen.paramPins[1].asInt) }
        } else if let singlePulse = runtimeNode?.block as? SinglePulseBlock {
            if singlePulse.paramPins.count > 0 { self.pulseGenTOn = max(1, singlePulse.paramPins[0].asInt) }
        } else if let pulseLen = runtimeNode?.block as? PulseLengthBlock {
            if pulseLen.paramPins.count > 0 { self.pulseGenTOn = max(1, pulseLen.paramPins[0].asInt) }
        } else {
            if mod.paramPins.count > 0 { self.pulseGenTOn = max(1, mod.paramPins[0].value.asInt) }
            if mod.paramPins.count > 1 { self.pulseGenTOff = max(1, mod.paramPins[1].value.asInt) }
        }

        // Counter & AdvCounter
        if let counter = runtimeNode?.block as? CounterBlock {
            if counter.paramPins.count > 0 { self.counterStep = counter.paramPins[0].asInt }
        } else if let advCounter = runtimeNode?.block as? AdvCounterBlock {
            if advCounter.paramPins.count > 0 { self.counterPreset = advCounter.paramPins[0].asInt }
            if advCounter.paramPins.count > 1 { self.counterMax = advCounter.paramPins[1].asInt }
            if advCounter.paramPins.count > 2 { self.counterMin = advCounter.paramPins[2].asInt }
            if advCounter.paramPins.count > 3 { self.counterStep = advCounter.paramPins[3].asInt }
        } else if mod.paramPins.count >= 1 {
            self.counterStep = mod.paramPins[0].value.asInt
        }

        // Timer
        if let timer = runtimeNode?.block as? TimerBlock {
            self.timerMode = timer.mode
            if timer.paramPins.count > 0 { self.timerPreset = max(1, timer.paramPins[0].asInt) }
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
        if let mean = runtimeNode?.block as? MeanBlock, mean.paramPins.count > 0 {
            self.meanWindow = max(1, mean.paramPins[0].asInt)
        }

        // Variables
        if let intVar = runtimeNode?.block as? IntVarBlock, intVar.outPins.count > 0 {
            self.intVarValue = intVar.outPins[0].asInt
        }
        if let floatVar = runtimeNode?.block as? FloatVarBlock, floatVar.outPins.count > 0 {
            self.floatVarValue = Double(floatVar.outPins[0].asFloat)
        }

        // Div Modulo
        self.divModuloVisible = mod.rawAttributes["MODULO_VISIBLE"]?.lowercased() == "true" || mod.rawAttributes["SHOW_MODULO"]?.lowercased() == "true" || (mod.outPins.count > 1)

        // RS Priority
        self.rsPriorityIsS = (mod.rawAttributes["PRIORITY"]?.uppercased() == "S") || (mod.rawAttributes["RS_PRIORITY"]?.uppercased() == "S")

        // DateTime
        self.dateTimeShowOffset = mod.rawAttributes["SHOW_OFFSET"]?.lowercased() == "true" || mod.rawAttributes["OFFSET_VISIBLE"]?.lowercased() == "true"
        self.dateTimeShowSOD = mod.rawAttributes["SHOW_SOD"]?.lowercased() == "true" || mod.rawAttributes["SOD_VISIBLE"]?.lowercased() == "true"

        // 8xPWM
        if let pwm = runtimeNode?.block as? EightPWMBlock {
            self.pwmSteps = pwm.pwmSteps
        } else if let s = mod.paramPins.first?.value.asInt {
            self.pwmSteps = s
        } else if let sStr = mod.rawAttributes["PWM_STEPS"], let s = Int(sStr) {
            self.pwmSteps = s
        }

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
                let cleaned = raw.replacingOccurrences(of: "$", with: "0x")
                return Int(cleaned, radix: cleaned.hasPrefix("0x") ? 16 : 10) ?? 0xFF
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
                let cleaned = raw.replacingOccurrences(of: "$", with: "0x")
                return Int(cleaned, radix: cleaned.hasPrefix("0x") ? 16 : 10) ?? 0
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

    private func applyChanges() {
        guard let mod = targetModule else { return }
        let cleanName = mod.name.filter { !$0.isNumber }.lowercased()

        if cleanName.contains("boolvar") || cleanName.contains("tlacitko") || cleanName.contains("prepinac") || cleanName.contains("roztoct") || mod.guid == BoolVarBlock.guid {
            model.updateBoolVarMode(id: moduleId, mode: boolVarMode)
            if let boolVar = runtimeNode?.block as? BoolVarBlock {
                boolVar.setOutput(boolVarInitialState)
            }
        } else if cleanName.contains("pulsegen") {
            model.updatePulseGenTiming(id: moduleId, tOn: pulseGenTOn, tOff: pulseGenTOff)
        } else if cleanName.contains("singlepulse") || cleanName.contains("pulselen") {
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(pulseGenTOn)))
        } else if cleanName.contains("counter") && !cleanName.contains("adv") {
            model.updateCounterStep(id: moduleId, step: counterStep)
        } else if cleanName.contains("advcounter") || cleanName == "cnt" {
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(counterPreset)))
            model.updateModuleParam(id: moduleId, paramIndex: 1, value: .int32(Int32(counterMax)))
            model.updateModuleParam(id: moduleId, paramIndex: 2, value: .int32(Int32(counterMin)))
            model.updateModuleParam(id: moduleId, paramIndex: 3, value: .int32(Int32(counterStep)))
        } else if cleanName.contains("timer") {
            if let timer = runtimeNode?.block as? TimerBlock {
                timer.mode = timerMode
            }
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(timerPreset)))
        } else if cleanName.contains("ramp") {
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(rampStepUp)))
            model.updateModuleParam(id: moduleId, paramIndex: 1, value: .int32(Int32(rampStepDown)))
        } else if cleanName.contains("limiter") || cleanName.contains("inrange") {
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(limiterMin)))
            model.updateModuleParam(id: moduleId, paramIndex: 1, value: .int32(Int32(limiterMax)))
        } else if cleanName.contains("mean") {
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(meanWindow)))
        } else if cleanName.contains("intvar") || cleanName.contains("longvar") {
            // `IntVar` has no parameters — the help gives it a single output — so the initial
            // value is stored as an attribute and pushed into the live block.
            model.setModuleRawAttribute(id: moduleId, key: "INIT_VALUE", value: "\(intVarValue)")
            (model.getNode(id: moduleId)?.block as? IntVarBlock)?.setValue(Int32(intVarValue))
        } else if cleanName.contains("floatvar") {
            model.setModuleRawAttribute(id: moduleId, key: "INIT_VALUE", value: "\(floatVarValue)")
            (model.getNode(id: moduleId)?.block as? FloatVarBlock)?.setValue(Float(floatVarValue))
        } else if cleanName.contains("div") && !cleanName.contains("fdiv") {
            model.updateDivModuloVisible(id: moduleId, isVisible: divModuloVisible)
        } else if cleanName == "rs" {
            model.updateRSPriority(id: moduleId, higherPriorityS: rsPriorityIsS)
        } else if cleanName.contains("datetime") {
            model.setModuleRawAttribute(id: moduleId, key: "SHOW_OFFSET", value: dateTimeShowOffset ? "True" : "False")
            model.setModuleRawAttribute(id: moduleId, key: "OFFSET_VISIBLE", value: dateTimeShowOffset ? "True" : "False")
            model.setModuleRawAttribute(id: moduleId, key: "SHOW_SOD", value: dateTimeShowSOD ? "True" : "False")
            model.setModuleRawAttribute(id: moduleId, key: "SOD_VISIBLE", value: dateTimeShowSOD ? "True" : "False")
        } else if cleanName.contains("8xpwm") || cleanName == "pwm" {
            model.updateModuleParam(id: moduleId, paramIndex: 0, value: .int32(Int32(pwmSteps)))
            model.setModuleRawAttribute(id: moduleId, key: "PWM_STEPS", value: "\(pwmSteps)")
            if let pwm = runtimeNode?.block as? EightPWMBlock {
                pwm.pwmSteps = pwmSteps
            }
        } else if cleanName.contains("case") {
            model.setModuleRawAttribute(id: moduleId, key: "VALUES", value: caseValuesText)
        } else if cleanName.contains("switch") && !cleanName.contains("end") {
            model.updateModuleInputCount(id: moduleId, count: inputCount)
        } else if cleanName.contains("intbits") || cleanName.contains("int2bits") {
            model.updateModuleOutputCount(id: moduleId, count: outputCount)
        } else if cleanName.contains("bitsint") || cleanName.contains("bits2int") {
            model.updateModuleInputCount(id: moduleId, count: inputCount)
        } else if cleanName.contains("demux") {
            model.updateModuleOutputCount(id: moduleId, count: outputCount)
        } else if cleanName == "and" || cleanName == "or" || cleanName.contains("orspin") || cleanName == "xor" || cleanName == "copy" {
            model.updateModuleInputCount(id: moduleId, count: inputCount)
        } else if cleanName.contains("xdi") || cleanName.contains("8xdi") || cleanName.contains("digitalinput") {
            var mask: Int = 0
            for bit in 0..<16 {
                if diMaskBits[bit] { mask |= (1 << bit) }
            }
            let hexStr = String(format: "$%04X", mask)
            model.update8xDIMask(id: moduleId, maskHex: hexStr, showWord: diShowWordOutput)
        } else if cleanName.contains("xdo") || cleanName.contains("8xdo") || cleanName.contains("digitaloutput") {
            var hiddenMask: Int = 0
            for bit in 0..<min(doPinCount, 16) {
                if !doVisibleBits[bit] { hiddenMask |= (1 << bit) }
            }
            let hexStr = String(format: "$%04X", hiddenMask)
            model.update8xDOConfig(id: moduleId, pinCount: doPinCount, hiddenMaskHex: hexStr)
        } else {
            // Apply generic parameters
            for (idx, valStr) in genericParamValues {
                let parsed = PinValue.parse(valStr)
                model.updateModuleParam(id: moduleId, paramIndex: idx, value: parsed)
            }
        }
    }
}
