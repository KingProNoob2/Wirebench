import Foundation
import WirebenchCore
import WirebenchLibrary

extension PCCModule {
    /// What the block *is*, as a lower-case word without digits (`iswitch`, `advcounter`): its type's name, never what a sheet called it.
    /// A block can be named anything — the agent calls its `ISwitch` `SnakePattern`, a person renames `ISwitch1` to `Pattern` — and a test on the
    /// name then takes it for something else. A type the catalogue does not know falls back to its name.
    public var typeKey: String {
        (BlockTypeCatalog.info(forGuid: guid)?.blockName ?? name).filter { !$0.isNumber }.lowercased()
    }
}

/// What a module is configured as. The test is on the module's type (see `typeKey`), in
/// the order below, which is the order both the form and `applyChanges` rely on.
public enum BlockConfigKind {
    case boolVar, pulseGen, singlePulse, counter, advCounter, timer, ramp, range, mean, intVar, floatVar
    case div, rs, dateTime, pwm, caseValues, switchInputs, int2Bits, bits2Int, demux, logic
    case digitalInputs, digitalOutputs, parameters, none
    case macroInterface, macroCall, systemCmd, switchCases

public init(_ mod: PCCModule) {
        // A macro's own blocks are recognised by what they are, not by what the sheet's author named them.
        if MacroInterface.kind(of: mod) != nil { self = .macroInterface; return }
        if MacroCalls.target(of: mod) != nil { self = .macroCall; return }
        if mod.guid == SystemCmdBlock.guid { self = .systemCmd; return }
        if ConstructContainers.isContainer(mod) && mod.guid == ConstructContainers.switchGuid { self = .switchCases; return }
        let n = mod.typeKey
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

/// What a block's configuration offers, as plain values: the fields for its kind, with their current values, and how
/// to write them back. The rules (which parameter is which, what is stored as an attribute) are the ones the
/// SwiftUI dialog applies, so every frontend configures a block the same way.
public struct BlockConfig: Codable, Sendable {
    public struct Option: Codable, Sendable {
        public var value: String
        public var label: String
    }

    public struct Field: Codable, Sendable {
        public var key: String
        public var label: String
        /// `int`, `bool`, `choice`, `text`, `bits` (a row of on/off channels, as `0`/`1` characters) or `cases` (a JSON list), `pins` (a JSON list of names, edited immediately), `info` (a read-only line) or `link` (a page to open).
        public var kind: String
        public var value: String
        public var min: Int?
        public var max: Int?
        public var options: [Option]?
        public var hint: String?
        /// For `bits`: how many channels, the name each carries (`DI` → DI0, DI1…), and the key of a number field that
        /// shortens the row.
        public var bitCount: Int? = nil
        public var prefix: String? = nil
        public var countKey: String? = nil
    }

    public var title: String
    public var fields: [Field]

    private static func int(_ key: String, _ label: String, _ value: Int, _ range: ClosedRange<Int>, hint: String? = nil) -> Field {
        Field(key: key, label: label, kind: "int", value: "\(value)", min: range.lowerBound, max: range.upperBound,
              options: nil, hint: hint)
    }

    private static func bool(_ key: String, _ label: String, _ value: Bool, hint: String? = nil) -> Field {
        Field(key: key, label: label, kind: "bool", value: value ? "1" : "0", min: nil, max: nil, options: nil, hint: hint)
    }

    private static func choice(_ key: String, _ label: String, _ value: String, _ options: [(String, String)],
                               hint: String? = nil) -> Field {
        Field(key: key, label: label, kind: "choice", value: value, min: nil, max: nil,
              options: options.map { Option(value: $0.0, label: $0.1) }, hint: hint)
    }

    /// The configuration of a block, or nil when its kind has nothing to configure here.
    @MainActor
    public static func make(of model: AppModel, moduleId: Int) -> BlockConfig? {
        guard let mod = model.module(id: moduleId) else { return nil }
        let live = model.getNode(id: moduleId)?.block
        let params = live?.paramPins ?? mod.paramPins.map(\.value)
        func param(_ i: Int, _ fallback: Int = 0) -> Int { params.indices.contains(i) ? params[i].asInt : fallback }
        func flag(_ keys: String...) -> Bool { keys.contains { mod.rawAttributes[$0]?.lowercased() == "true" } }

        var fields: [Field] = []
        switch BlockConfigKind(mod) {
        case .boolVar:
            let mode = BlockRole.boolVarMode(of: mod) ?? .pushButton
            fields = [
                choice("mode", "Control type", "\(mode.rawValue)", [
                    ("\(BoolVarBlock.Mode.pushButton.rawValue)", "Push button (momentary pulse)"),
                    ("\(BoolVarBlock.Mode.toggleSwitch.rawValue)", "Button that stays set (latch)")]),
                bool("initial", "Initial state (1 = on)", live?.outPins.first?.asBool ?? false)]
        case .pulseGen:
            fields = [int("tOn", "Time on (cycles)", max(1, param(0, 1)), 1...10000),
                      int("tOff", "Time off (cycles)", max(1, param(1, 1)), 1...10000)]
        case .singlePulse:
            fields = [int("tOn", "Pulse duration (cycles)", max(1, param(0, 1)), 1...10000)]
        case .counter:
            fields = [int("step", "Step (St)", param(0, 1), -1000...1000)]
        case .advCounter:
            fields = [int("preset", "Preset (PV)", param(0), -10000...10000),
                      int("max", "Maximum (Max)", param(1), -10000...10000),
                      int("min", "Minimum (Min)", param(2), -10000...10000),
                      int("step", "Step (St)", param(3, 1), -1000...1000)]
        case .timer:
            let raw = Int(mod.rawAttributes["MODE"] ?? "0") ?? 0
            fields = [choice("mode", "Timer type", "\(raw)", [
                          ("0", "On-delay (TON)"), ("1", "Continuous on-delay"), ("2", "Fixed pulse (TP)"), ("3", "Truncated pulse")]),
                      int("preset", "Preset time (PT ticks)", max(1, param(0, 1)), 1...100000)]
        case .ramp:
            fields = [int("up", "Step up (SU per cycle)", max(1, mod.paramPins.first?.value.asInt ?? 1), 1...10000),
                      int("down", "Step down (SD per cycle)", max(1, mod.paramPins.dropFirst().first?.value.asInt ?? 1), 1...10000)]
        case .range:
            fields = [int("min", "Minimum", mod.paramPins.first?.value.asInt ?? 0, -100000...100000),
                      int("max", "Maximum", mod.paramPins.dropFirst().first?.value.asInt ?? 0, -100000...100000)]
        case .mean:
            fields = [int("window", "Sample window size", max(1, param(0, 1)), 1...128)]
        case .intVar:
            fields = [int("value", "Initial value", live?.outPins.first?.asInt ?? 0, -2_000_000_000...2_000_000_000),
                      int("sliderMax", "Slider maximum", BlockRole.sliderMax(of: mod), 1...2_000_000_000)]
        case .floatVar:
            fields = [Field(key: "value", label: "Initial value", kind: "text",
                            value: "\(Double(live?.outPins.first?.asFloat ?? 0))", min: nil, max: nil, options: nil, hint: nil)]
        case .div:
            fields = [bool("modulo", "Show modulo output pin (Mod = A % B)",
                           flag("MODULO_VISIBLE", "SHOW_MODULO") || mod.outPins.count > 1)]
        case .rs:
            let setFirst = ["PRIORITY", "RS_PRIORITY"].contains { mod.rawAttributes[$0]?.uppercased() == "S" }
            fields = [choice("priority", "When both S and R are 1", setFirst ? "S" : "R", [
                ("R", "Reset dominant (*R)"), ("S", "Set dominant (*S)")])]
        case .dateTime:
            fields = [bool("offset", "Input pin offset (Offs in seconds)", flag("SHOW_OFFSET", "OFFSET_VISIBLE")),
                      bool("sod", "Output pin SOD (second of day)", flag("SHOW_SOD", "SOD_VISIBLE"))]
        case .pwm:
            fields = [int("steps", "PWM steps", max(2, mod.paramPins.first?.value.asInt
                                                    ?? mod.rawAttributes["PWM_STEPS"].flatMap { Int($0) } ?? 256), 2...65535)]
        case .caseValues:
            fields = [Field(key: "values", label: "Case values and ranges", kind: "text",
                            value: mod.rawAttributes["VALUES"] ?? mod.rawAttributes["CASE_VALUES"] ?? "",
                            min: nil, max: nil, options: nil, hint: "For example 1, 3, 5-9")]
        case .switchInputs, .bits2Int, .logic:
            let name = mod.typeKey
            let count = mod.rawAttributes["INPUT_COUNT"].flatMap { Int($0) }
                ?? (name.contains("switch") ? max(mod.inPins.count - 2, 2)
                    : name.contains("bitsint") || name.contains("bits2int") ? max(mod.inPins.count, 8)
                    : max(mod.inPins.count - 1, 2))
            fields = [int("inputs", "Number of inputs", count, 1...16)]
        case .int2Bits, .demux:
            let name = mod.typeKey
            let count = mod.rawAttributes["OUTPUT_COUNT"].flatMap { Int($0) }
                ?? (name.contains("demux") ? max(mod.outPins.count, 4) : max(mod.outPins.count, 8))
            fields = [int("outputs", "Number of outputs", count, 1...(BlockConfigKind(mod) == .demux ? 126 : 16))]
        case .digitalInputs:
            let mask = mod.rawAttributes["PIN_MASK"].map(PinMask.parse) ?? 0xFF
            fields = [Field(key: "mask", label: "Visible pins", kind: "bits",
                            value: String((0..<16).map { mask & (1 << $0) != 0 ? "1" : "0" }),
                            min: nil, max: nil, options: nil, hint: "Which digital inputs (DI0..DI15) the block shows.",
                            bitCount: 16, prefix: "DI"),
                      bool("showWord", "Word output (all inputs as one 16-bit integer)",
                           mod.rawAttributes["PIN_ALL_VISIBLE"]?.lowercased() == "true")]
        case .digitalOutputs:
            let count = mod.rawAttributes["PIN_COUNT"].flatMap { Int($0) } ?? max(mod.inPins.count, 8)
            let hidden = mod.rawAttributes["HIDDEN_PIN_MASK"].map(PinMask.parse) ?? 0
            fields = [int("pinCount", "Pin count", count, 1...32),
                      Field(key: "visible", label: "Visible output channels", kind: "bits",
                            value: String((0..<16).map { hidden & (1 << $0) == 0 ? "1" : "0" }),
                            min: nil, max: nil, options: nil, hint: nil, bitCount: 16, prefix: "DO", countKey: "pinCount")]
        case .switchCases:
            let cases = ConstructContainers.cases(of: mod).map { ["id": $0.id, "values": $0.values] }
            let json = (try? JSONSerialization.data(withJSONObject: cases)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            fields = [Field(key: "cases", label: "Cases", kind: "cases", value: json, min: nil, max: nil, options: nil,
                            hint: "Each case lists the values it matches, like 1, 5..7, 9. Empty cases are removed."),
                      bool("default", "Has a default arm", mod.rawAttributes["DEFAULT"] == "1")]
        case .macroInterface:
            let names = MacroInterface.pinNames(of: mod)
            let json = (try? JSONSerialization.data(withJSONObject: names)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let inputs = MacroInterface.kind(of: mod) == .inputs
            fields = [Field(key: "pins", label: inputs ? "Macro inputs" : "Macro outputs", kind: "pins", value: json,
                            min: nil, max: nil, options: nil,
                            hint: "Every call of this macro gets the same pins. Names are saved when you press Return.")]
        case .macroCall:
            guard let name = MacroCalls.target(of: mod) else { return nil }
            fields = [Field(key: "calls", label: "Calls", kind: "info", value: "*" + name, min: nil, max: nil, options: nil,
                            hint: "The pins follow the macro's Inputs and Outputs blocks."),
                      Field(key: "open", label: "Open macro", kind: "link", value: "*" + name, min: nil, max: nil, options: nil,
                            hint: nil)]
        case .systemCmd:
            let catalogue = model.systemCommandCatalogue
            let current = model.systemCommand(of: mod)
            // A command the project uses but the profile does not list stays selectable.
            let known = current.map { c in catalogue.contains { $0.command == c.command && $0.text == c.text } ? catalogue : [c] + catalogue } ?? catalogue
            fields = [Field(key: "command", label: "Command", kind: "choice", value: current?.selectionTag ?? "", min: nil, max: nil,
                            options: [Option(value: "", label: "None — set the command word on the Cmd pin")]
                                + known.map { Option(value: $0.selectionTag, label: "\($0.title)  ·  \($0.text)") },
                            hint: "The pins are named after the command, and only the ones it uses are written to the PLC.")]
            if let current {
                func line(_ pin: SystemCommandInfo.PinSchema) -> String { pin.isHidden ? "not used" : "\(pin.name) (\(pin.dataType))" }
                fields += [Field(key: "word", label: "Command word", kind: "info", value: String(format: "0x%04X", current.command), min: nil, max: nil, options: nil, hint: nil),
                           Field(key: "p1", label: "Parameter 1", kind: "info", value: line(current.input1), min: nil, max: nil, options: nil, hint: nil),
                           Field(key: "p2", label: "Parameter 2", kind: "info", value: line(current.input2), min: nil, max: nil, options: nil, hint: nil),
                           Field(key: "result", label: "Result", kind: "info", value: line(current.output), min: nil, max: nil, options: nil, hint: nil)]
            }
            fields += mod.paramPins.indices.map { i in
                Field(key: "param\(i)", label: ModulePinCatalog.paramPinFullName(for: mod, index: i), kind: "text",
                      value: mod.paramPins[i].value.description, min: nil, max: nil, options: nil, hint: nil)
            }
        case .parameters:
            fields = mod.paramPins.indices.map { i in
                Field(key: "param\(i)", label: ModulePinCatalog.paramPinFullName(for: mod, index: i), kind: "text",
                      value: mod.paramPins[i].value.description, min: nil, max: nil, options: nil, hint: nil)
            }
        default:
            return nil
        }
        return fields.isEmpty ? nil : BlockConfig(title: mod.name, fields: fields)
    }

    /// Writes edited values (by field key) to the block, as the SwiftUI dialog's Apply does.
    @MainActor
    public static func apply(_ values: [String: String], to moduleId: Int, in model: AppModel) {
        guard let mod = model.module(id: moduleId) else { return }
        func number(_ key: String) -> Int? { values[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func on(_ key: String) -> Bool { values[key] == "1" }
        func setParam(_ index: Int, _ key: String) {
            if let v = number(key) { model.updateModuleParam(id: moduleId, paramIndex: index, value: .int32(Int32(clamping: v))) }
        }
        func showAttribute(_ keys: [String], _ shown: Bool) {
            for key in keys { model.setModuleRawAttribute(id: moduleId, key: key, value: shown ? "True" : "False") }
        }

        switch BlockConfigKind(mod) {
        case .boolVar:
            if let raw = number("mode"), let mode = BoolVarBlock.Mode(rawValue: raw) { model.updateBoolVarMode(id: moduleId, mode: mode) }
            model.setModuleOutput(moduleId: moduleId, pinIndex: 0, value: .bool(on("initial")))
        case .pulseGen:
            if let a = number("tOn"), let b = number("tOff") { model.updatePulseGenTiming(id: moduleId, tOn: a, tOff: b) }
        case .singlePulse: setParam(0, "tOn")
        case .counter:
            if let step = number("step") { model.updateCounterStep(id: moduleId, step: step) }
        case .advCounter:
            setParam(0, "preset"); setParam(1, "max"); setParam(2, "min"); setParam(3, "step")
        case .timer:
            if let mode = number("mode") {
                model.setModuleRawAttribute(id: moduleId, key: "MODE", value: "\(mode)")
                model.reconfigureModule(id: moduleId)
            }
            setParam(0, "preset")
        case .ramp: setParam(0, "up"); setParam(1, "down")
        case .range: setParam(0, "min"); setParam(1, "max")
        case .mean: setParam(0, "window")
        case .intVar:
            if let v = number("value") {
                model.setModuleRawAttribute(id: moduleId, key: "INIT_VALUE", value: "\(v)")
                model.setVariableValue(moduleId: moduleId, value: v)
            }
            if let m = number("sliderMax") { model.setSliderMax(id: moduleId, max: m) }
        case .floatVar:
            if let text = values["value"], let v = Double(text) {
                model.setModuleRawAttribute(id: moduleId, key: "INIT_VALUE", value: "\(v)")
                model.setFloatVariableValue(moduleId: moduleId, value: Float(v))
            }
        case .div: model.updateDivModuloVisible(id: moduleId, isVisible: on("modulo"))
        case .rs: model.updateRSPriority(id: moduleId, higherPriorityS: values["priority"] == "S")
        case .dateTime:
            showAttribute(["SHOW_OFFSET", "OFFSET_VISIBLE"], on("offset"))
            showAttribute(["SHOW_SOD", "SOD_VISIBLE"], on("sod"))
        case .pwm:
            setParam(0, "steps")
            if let v = number("steps") { model.setModuleRawAttribute(id: moduleId, key: "PWM_STEPS", value: "\(v)") }
        case .caseValues:
            if let text = values["values"] { model.setModuleRawAttribute(id: moduleId, key: "VALUES", value: text) }
        case .switchInputs, .bits2Int, .logic:
            if let c = number("inputs") { model.updateModuleInputCount(id: moduleId, count: c) }
        case .int2Bits, .demux:
            if let c = number("outputs") { model.updateModuleOutputCount(id: moduleId, count: c) }
        case .digitalInputs:
            let word = (0..<16).reduce(0) { $0 | ((values["mask"]?.dropFirst($1).first == "1") ? 1 << $1 : 0) }
            model.update8xDIMask(id: moduleId, maskHex: String(format: "$%04X", word), showWord: on("showWord"))
        case .digitalOutputs:
            let count = number("pinCount") ?? 8
            let hidden = (0..<min(count, 16)).reduce(0) { $0 | ((values["visible"]?.dropFirst($1).first == "1") ? 0 : 1 << $1) }
            model.update8xDOConfig(id: moduleId, pinCount: count, hiddenMaskHex: String(format: "$%04X", hidden))
        case .switchCases:
            let raw = (values["cases"]?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: String]] ?? []
            // `|` and `:` are the format's separators, never part of a value list; a case left empty is removed.
            var cases: [ConstructContainers.Case] = []
            for item in raw {
                let clean = (item["values"] ?? "").filter { $0 != "|" && $0 != ":" }.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { continue }
                // A case added in the form has no id yet; the id is what a member's `ARM` holds, so it is permanent.
                let id = (item["id"] ?? "").isEmpty ? ConstructContainers.newCaseId(among: cases) : item["id"]!
                cases.append(ConstructContainers.Case(id: id, values: clean))
            }
            model.setSwitchCases(of: moduleId, to: cases, hasDefault: on("default"))
        case .systemCmd:
            let catalogue = model.systemCommandCatalogue
            if let tag = values["command"] { model.setSystemCommand(moduleId: moduleId, to: catalogue.first { $0.selectionTag == tag }) }
            for (key, text) in values where key.hasPrefix("param") {
                if let index = Int(key.dropFirst(5)) {
                    model.updateModuleParam(id: moduleId, paramIndex: index, value: PinValue.parse(text))
                }
            }
        case .parameters:
            for (key, text) in values where key.hasPrefix("param") {
                if let index = Int(key.dropFirst(5)) {
                    model.updateModuleParam(id: moduleId, paramIndex: index, value: PinValue.parse(text))
                }
            }
        default: break
        }
    }
}
