import Foundation
import WirebenchCore
import WirebenchLibrary

public enum MaraflowConfiguration {
    public static let coilDefinitionIDs: Set<String> = [
        "Ladder.Coil.NORMAL", "Ladder.Coil.NEGATED", "Ladder.Coil.SET", "Ladder.Coil.RESET",
        "Ladder.Coil.POS", "Ladder.Coil.NEG", "Ladder.Coil.WRITE_REG", "Ladder.Coil.ANALOG",
    ]

    public static func defaultOperand(for definitionID: String) -> String {
        switch definitionID {
        case "Ladder.Coil.ANALOG": return "AO0"
        case "Ladder.Coil.WRITE_REG": return "REG_0"
        default: return "DO0"
        }
    }

    public static let timeZonePresets: [String: [String: String]] = [
        "UTC": ["TzStdOffsetMin": "0", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Europe/Prague": ["TzStdOffsetMin": "60", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "-1", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "10", "TzDstEndWeek": "-1", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Europe/London": ["TzStdOffsetMin": "0", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "-1", "TzDstStartDow": "0", "TzDstStartHour": "1", "TzDstEndMonth": "10", "TzDstEndWeek": "-1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "Europe/Athens": ["TzStdOffsetMin": "120", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "-1", "TzDstStartDow": "0", "TzDstStartHour": "3", "TzDstEndMonth": "10", "TzDstEndWeek": "-1", "TzDstEndDow": "0", "TzDstEndHour": "4"],
        "Europe/Moscow": ["TzStdOffsetMin": "180", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "America/New_York": ["TzStdOffsetMin": "-300", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "2", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "11", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "America/Chicago": ["TzStdOffsetMin": "-360", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "2", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "11", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "America/Denver": ["TzStdOffsetMin": "-420", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "2", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "11", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "America/Phoenix": ["TzStdOffsetMin": "-420", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "America/Los_Angeles": ["TzStdOffsetMin": "-480", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "2", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "11", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "America/Anchorage": ["TzStdOffsetMin": "-540", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "2", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "11", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "Pacific/Honolulu": ["TzStdOffsetMin": "-600", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "America/St_Johns": ["TzStdOffsetMin": "-210", "TzDstOffsetMin": "60", "TzDstStartMonth": "3", "TzDstStartWeek": "2", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "11", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "America/Sao_Paulo": ["TzStdOffsetMin": "-180", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "America/Santiago": ["TzStdOffsetMin": "-240", "TzDstOffsetMin": "60", "TzDstStartMonth": "9", "TzDstStartWeek": "1", "TzDstStartDow": "6", "TzDstStartHour": "24", "TzDstEndMonth": "4", "TzDstEndWeek": "1", "TzDstEndDow": "6", "TzDstEndHour": "24"],
        "Asia/Dubai": ["TzStdOffsetMin": "240", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Asia/Kolkata": ["TzStdOffsetMin": "330", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Asia/Kathmandu": ["TzStdOffsetMin": "345", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Asia/Shanghai": ["TzStdOffsetMin": "480", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Asia/Tokyo": ["TzStdOffsetMin": "540", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Australia/Adelaide": ["TzStdOffsetMin": "570", "TzDstOffsetMin": "60", "TzDstStartMonth": "10", "TzDstStartWeek": "1", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "4", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Australia/Sydney": ["TzStdOffsetMin": "600", "TzDstOffsetMin": "60", "TzDstStartMonth": "10", "TzDstStartWeek": "1", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "4", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Australia/Lord_Howe": ["TzStdOffsetMin": "630", "TzDstOffsetMin": "30", "TzDstStartMonth": "10", "TzDstStartWeek": "1", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "4", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "2"],
        "Pacific/Auckland": ["TzStdOffsetMin": "720", "TzDstOffsetMin": "60", "TzDstStartMonth": "9", "TzDstStartWeek": "-1", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "4", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Pacific/Chatham": ["TzStdOffsetMin": "765", "TzDstOffsetMin": "60", "TzDstStartMonth": "9", "TzDstStartWeek": "-1", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "4", "TzDstEndWeek": "1", "TzDstEndDow": "0", "TzDstEndHour": "3"],
        "Pacific/Kiritimati": ["TzStdOffsetMin": "840", "TzDstOffsetMin": "0", "TzDstStartMonth": "0", "TzDstStartWeek": "0", "TzDstStartDow": "0", "TzDstStartHour": "2", "TzDstEndMonth": "0", "TzDstEndWeek": "0", "TzDstEndDow": "0", "TzDstEndHour": "3"],
    ]

    public static func value(_ value: PinValue, as dataType: String) -> PinValue {
        switch dataType.uppercased() {
        case "BOOL": return .bool(value.asBool)
        case "LONG": return .int64(Int64(value.asInt))
        case "FLOAT": return .float(value.asFloat)
        default: return .int32(value.asInt32)
        }
    }

    public static func typeName(of value: PinValue) -> String {
        switch value {
        case .bool: return "BOOL"
        case .int64: return "LONG"
        case .float: return "FLOAT"
        default: return "INT"
        }
    }

    public static func dataType(of module: PCCModule) -> String {
        if let configured = module.rawAttributes["MARAFLOW_PROP_DataType"] { return configured.uppercased() }
        if let definition = MaraflowCatalog.definition(forGuid: module.guid), definition.configurableDataType {
            return MaraflowCatalog.declaredDataType(for: definition)
        }
        if let output = module.outPins.first?.value { return typeName(of: output) }
        if module.inPins.count > 1 { return typeName(of: module.inPins[1].value) }
        return "INT"
    }

    public static func inputCount(of module: PCCModule) -> Int? {
        guard let definition = MaraflowCatalog.definition(forGuid: module.guid), definition.variableInputCount else { return nil }
        if let configured = module.rawAttributes["MARAFLOW_PROP_InputCount"].flatMap(Int.init) { return configured }
        let fixed = definition.id == "Main.Switches.Mux" ? 2 : 1
        return max(2, module.inPins.count - fixed)
    }
}

public extension AppModel {
    func updateMaraflowInputCount(id: Int, count: Int) {
        guard let index = project?.modules.firstIndex(where: { $0.id == id }),
              let module = project?.modules[index],
              let definition = MaraflowCatalog.definition(forGuid: module.guid), definition.variableInputCount else { return }
        let count = min(16, max(2, count))
        let fixed = definition.id == "Main.Switches.Mux" ? 2 : 1
        let dataType = MaraflowConfiguration.dataType(of: module)
        let oldPins = module.inPins.dropFirst(fixed)
        var pins = Array(module.inPins.prefix(fixed))
        for index in pins.indices where pins[index].name == nil {
            pins[index].name = definition.inputs[index].abbrev
        }
        for operand in 0..<count {
            let old = operand < oldPins.count ? oldPins[oldPins.index(oldPins.startIndex, offsetBy: operand)] : nil
            let name = definition.id == "Main.Switches.Mux" ? "X\(operand)" : "X\(operand + 1)"
            pins.append(Pin(id: fixed + operand,
                            value: MaraflowConfiguration.value(old?.value ?? .int32(0), as: dataType),
                            inverted: old?.inverted ?? false, rights: old?.rights ?? 0, name: name,
                            format: old?.format, rawAttributes: old?.rawAttributes ?? [:]))
        }
        project?.modules[index].inPins = pins
        project?.modules[index].inputCount = count
        project?.modules[index].rawAttributes["MARAFLOW_PROP_InputCount"] = "\(count)"
        project?.inConnections.removeAll { $0.inModuleId == id && $0.inPinId >= fixed + count }
        isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    func updateMaraflowDataType(id: Int, dataType: String) {
        let dataType = dataType.uppercased()
        guard ["BOOL", "INT", "LONG", "FLOAT"].contains(dataType),
              let index = project?.modules.firstIndex(where: { $0.id == id }),
              let module = project?.modules[index],
              let definition = MaraflowCatalog.definition(forGuid: module.guid), definition.configurableDataType else { return }
        project?.modules[index].rawAttributes["MARAFLOW_PROP_DataType"] = dataType
        let excludedInputs: Set<String> = ["En", "Adr", "G", "Idx", "Rst"]
        let excludedOutputs: Set<String> = ["Ok", "Err", "Oob", "Rdy", "Sts", "Flg"]
        for (pinIndex, pin) in module.inPins.enumerated() {
            let abbreviation = pin.name ?? (definition.inputs.indices.contains(pinIndex)
                ? definition.inputs[pinIndex].abbrev : definition.inputs.last?.abbrev ?? "")
            if !excludedInputs.contains(abbreviation) {
                project?.modules[index].inPins[pinIndex].value = MaraflowConfiguration.value(pin.value, as: dataType)
            }
        }
        if !definition.id.hasPrefix("Main.Comparators.") {
            for (pinIndex, pin) in module.outPins.enumerated() {
                let abbreviation = pin.name ?? (definition.outputs.indices.contains(pinIndex)
                    ? definition.outputs[pinIndex].abbrev : "Mod")
                if !excludedOutputs.contains(abbreviation) {
                    project?.modules[index].outPins[pinIndex].value = MaraflowConfiguration.value(pin.value, as: dataType)
                }
            }
        }
        isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    func updateMaraflowOperand(id: Int, operand: String) {
        let operand = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operand.isEmpty,
              let index = project?.modules.firstIndex(where: { $0.id == id }),
              let module = project?.modules[index],
              let definition = MaraflowCatalog.definition(forGuid: module.guid),
              MaraflowConfiguration.coilDefinitionIDs.contains(definition.id) else { return }
        project?.modules[index].rawAttributes["MARAFLOW_PROP_Operand"] = operand
        isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    func updateMaraflowProperty(id: Int, name: String, value: String) {
        guard let index = project?.modules.firstIndex(where: { $0.id == id }),
              let module = project?.modules[index],
              let definition = MaraflowCatalog.definition(forGuid: module.guid) else { return }
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "DeviceAddressHex", definition.id == "Comm.I2C.TMP75" {
            value = String(value.split(separator: " ").first ?? "0x48")
        } else if name == "DisplayMode" {
            value = value.hasPrefix("Raw") ? "Raw Digits / Segments" : "Number (Float / Int)"
        } else if name == "DigitMask" {
            value = String((0..<4).map { position -> Character in
                guard position < value.count else { return "0" }
                let character = value[value.index(value.startIndex, offsetBy: position)]
                return "1TtXx".contains(character) ? "1" : "0"
            })
        }
        project?.modules[index].rawAttributes["MARAFLOW_PROP_\(name)"] = value
        if name == "TimeZone", value != "Custom", let preset = MaraflowConfiguration.timeZonePresets[value] {
            for (key, presetValue) in preset {
                project?.modules[index].rawAttributes["MARAFLOW_PROP_\(key)"] = presetValue
            }
        }

        if name == "Channel", definition.id == "IO.IREF" || definition.id == "IO.OREF" {
            let analog = value.uppercased().hasPrefix("AI") || value.uppercased().hasPrefix("AO")
            if definition.id == "IO.IREF", !module.outPins.isEmpty {
                let old = module.outPins[0]
                if MaraflowConfiguration.typeName(of: old.value) != (analog ? "INT" : "BOOL") {
                    project?.inConnections.removeAll { $0.outModuleId == id && $0.outPinId == old.id }
                }
                project?.modules[index].outPins[0].value = analog ? .int32(old.value.asInt32) : .bool(old.value.asBool)
            } else if definition.id == "IO.OREF", !module.inPins.isEmpty {
                let old = module.inPins[0]
                if MaraflowConfiguration.typeName(of: old.value) != (analog ? "INT" : "BOOL") {
                    project?.inConnections.removeAll { $0.inModuleId == id && $0.inPinId == old.id }
                }
                project?.modules[index].inPins[0].value = analog ? .int32(old.value.asInt32) : .bool(old.value.asBool)
            }
        }

        if definition.id == "IO.CH455G", name == "DisplayMode" || name == "DigitMask" {
            let mode = project?.modules[index].rawAttributes["MARAFLOW_PROP_DisplayMode"] ?? "Number (Float / Int)"
            let rawMask = project?.modules[index].rawAttributes["MARAFLOW_PROP_DigitMask"] ?? "1111"
            let mask = String((0..<4).map { position -> Character in
                guard position < rawMask.count else { return "0" }
                let character = rawMask[rawMask.index(rawMask.startIndex, offsetBy: position)]
                return "1TtXx".contains(character) ? "1" : "0"
            })
            project?.modules[index].rawAttributes["MARAFLOW_PROP_DigitMask"] = mask
            var oldByName: [String: Pin] = [:]
            for pin in module.inPins {
                if let name = pin.name { oldByName[name] = pin }
            }
            func pin(_ position: Int, _ name: String, _ fallback: PinValue) -> Pin {
                let old = oldByName[name] ?? (name == "En" ? module.inPins.first : nil)
                return Pin(id: position, value: old?.value ?? fallback, inverted: old?.inverted ?? false,
                           rights: old?.rights ?? 0, name: name, format: old?.format,
                           rawAttributes: old?.rawAttributes ?? [:])
            }
            var pins = [pin(0, "En", .bool(true))]
            if mode.hasPrefix("Raw") {
                for digit in 0..<4 where mask[mask.index(mask.startIndex, offsetBy: digit)] == "1" {
                    pins.append(pin(pins.count, "D\(digit)", .int32(0)))
                }
                pins.append(pin(pins.count, "DpMask", .int32(0)))
                pins.append(pin(pins.count, "Brt", .int32(8)))
            } else {
                pins.append(pin(pins.count, "Val", .float(0)))
                pins.append(pin(pins.count, "Dec", .int32(1)))
                pins.append(pin(pins.count, "Brt", .int32(8)))
            }
            let newIndices = pins.enumerated().reduce(into: [String: Int]()) { result, item in
                if let name = item.element.name, result[name] == nil { result[name] = item.offset }
            }
            let connections = project?.inConnections.compactMap { connection -> Connection? in
                guard connection.inModuleId == id else { return connection }
                guard module.inPins.indices.contains(connection.inPinId) else { return nil }
                let oldIndex = connection.inPinId
                let name = module.inPins[oldIndex].name ?? (definition.inputs.indices.contains(oldIndex)
                    ? definition.inputs[oldIndex].abbrev : nil)
                guard let name, let newIndex = newIndices[name] else { return nil }
                var connection = connection
                connection.inPinId = newIndex
                return connection
            }
            project?.modules[index].inPins = pins
            if let connections { project?.inConnections = connections }
        }

        if name == "CurrentValue", definition.id.hasPrefix("Visual.Vars."), !module.outPins.isEmpty {
            let parsed = PinValue.parse(value)
            project?.modules[index].outPins[0].value = MaraflowConfiguration.value(parsed,
                as: MaraflowConfiguration.typeName(of: module.outPins[0].value))
        }
        isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    func updateMaraflowDivModuloOut(id: Int, isVisible: Bool) {
        guard let index = project?.modules.firstIndex(where: { $0.id == id }),
              let module = project?.modules[index],
              MaraflowCatalog.definition(forGuid: module.guid)?.id == "Math.Div" else { return }
        project?.modules[index].rawAttributes["MARAFLOW_PROP_ModuloOut"] = isVisible ? "true" : "false"
        if isVisible, module.outPins.count < 3 {
            let dataType = MaraflowConfiguration.dataType(of: module)
            project?.modules[index].outPins.append(Pin(id: 2,
                value: MaraflowConfiguration.value(.int32(0), as: dataType), rights: 2, name: "Mod"))
        } else if !isVisible, module.outPins.count > 2 {
            project?.modules[index].outPins.removeSubrange(2...)
        }
        if !isVisible {
            project?.inConnections.removeAll { $0.outModuleId == id && $0.outPinId >= 2 }
        }
        isDocumentEdited = true
        rebuildAfterShapeChange()
    }
}
