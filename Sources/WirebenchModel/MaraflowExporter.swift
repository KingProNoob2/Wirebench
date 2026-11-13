import Foundation
import WirebenchCore
import WirebenchLibrary

public enum MaraflowExportError: Error, LocalizedError {
    case notImported
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notImported:
            return "This project was not imported from Maraflow, so there is no Maraflow project to export."
        case .writeFailed(let detail):
            return "The Maraflow project could not be written: \(detail)"
        }
    }
}

public struct MaraflowExportResult {
    public let data: Data
    public let notes: [String]
}

/// Writes the current project back as a Maraflow `.mfl` properties document.
///
/// The preserved `.mfl` table is the base, so fields Wirebench does not model (tags, safety rules, bus ids, route
/// points, unknown keys) survive unchanged. The current pages, native blocks and wires are laid over it; a block or a
/// page that has no Maraflow representation is reported instead of being silently dropped.
public enum MaraflowExporter {
    /// Dirigo types with a direct Maraflow counterpart. `inputs`/`outputs` map a Maraflow pin index to the Dirigo pin
    /// index it should read; pins the map leaves out take the Maraflow definition's default.
    struct Bridge {
        let definitionId: String
        var inputs: [Int: Int] = [:]
        var outputs: [Int: Int] = [:]
    }

    static func bridge(for info: BlockTypeInfo) -> Bridge? {
        switch info.blockName {
        case "And": return Bridge(definitionId: "Bool.And")
        case "Or": return Bridge(definitionId: "Bool.Or")
        case "Xor": return Bridge(definitionId: "Bool.Xor")
        case "Not": return Bridge(definitionId: "Bool.Not")
        case "RS": return Bridge(definitionId: "Bool.RS")
        case "IAdd": return Bridge(definitionId: "Math.Add")
        case "ISub": return Bridge(definitionId: "Math.Sub")
        case "IMul": return Bridge(definitionId: "Math.Mul")
        case "IAbs": return Bridge(definitionId: "Math.Abs")
        case "INeg": return Bridge(definitionId: "Math.Neg")
        case "FSqrt": return Bridge(definitionId: "Math.Sqrt")
        case "FSin": return Bridge(definitionId: "Math.Sin")
        case "FCos": return Bridge(definitionId: "Math.Cos")
        case "FAdd": return Bridge(definitionId: "Math.Add")
        case "FSub": return Bridge(definitionId: "Math.Sub")
        case "FMul": return Bridge(definitionId: "Math.Mul")
        case "ISwitch": return Bridge(definitionId: "Main.Switches.Sel")
        case "IDemux": return Bridge(definitionId: "Main.Switches.Demux")
        case "8xDI": return Bridge(definitionId: "IO.8xDI")
        case "8xDO": return Bridge(definitionId: "IO.8xDO")
        case "Segment": return Bridge(definitionId: "Visual.Segment")
        case "Value": return Bridge(definitionId: "Visual.Value")
        case "BoolVar": return Bridge(definitionId: "Visual.Vars.BoolVar")
        case "IntVar": return Bridge(definitionId: "Visual.Vars.IntVar")
        case "LongVar": return Bridge(definitionId: "Visual.Vars.LongVar")
        case "PulseGen": return Bridge(definitionId: "Main.Timers.PulseGen")
        case "SinglePulse": return Bridge(definitionId: "Main.Timers.SinglePulse")
        default: return nil
        }
    }

    public static func export(_ project: PCCProject) throws -> MaraflowExportResult {
        // An imported project keeps its verbatim table; a native project gets a minimal Maraflow envelope and whatever
        // native blocks it has. This is what lets Export Maraflow work without an import.
        let extras = project.maraflow
        var properties = extras?.properties ?? [:]
        var notes: [String] = []
        if extras == nil {
            notes.append("This project was not imported from Maraflow; only its Maraflow-native blocks and metadata were exported.")
        }

        func put(_ key: String, _ value: String) { properties[key] = value }
        func removePrefix(_ prefix: String) {
            for key in properties.keys where key.hasPrefix(prefix) { properties.removeValue(forKey: key) }
        }

        put("maraflow.version", (extras?.formatVersion.isEmpty == false) ? extras!.formatVersion : "1.0.0")
        if properties["project.targetPlatform"] == nil {
            put("project.targetPlatform", "STM32F407-Maraflow-Std")
        }
        if properties["project.defaultThreadId"] == nil { put("project.defaultThreadId", "2") }
        if properties["project.primaryLanguage"] == nil { put("project.primaryLanguage", "FBD") }
        put("project.name", project.name)
        put("project.author", project.author)
        put("project.description", project.description)
        put("project.pageCount", "\(project.pages.count)")

        // Every page's generated keys are replaced, while its preserved graphics/rungs/ST variable table stay.
        for pageIndex in 0..<project.pages.count {
            removePrefix("page.\(pageIndex).block.")
            removePrefix("page.\(pageIndex).wire.")
        }

        var exportedID: [Int: String] = [:]

        func typeName(of value: PinValue) -> String {
            switch value {
            case .bool: return "BOOL"
            case .int16, .int32: return "INT"
            case .int64: return "LONG"
            case .float: return "FLOAT"
            case .undefined: return "BOOL"
            }
        }

        func pinType(definition: MaraflowDefinition?, index: Int, output: Bool, fallback: PinValue) -> String {
            let specs = output ? definition?.outputs : definition?.inputs
            if let specs, specs.indices.contains(index) { return specs[index].dataType.uppercased() }
            return typeName(of: fallback)
        }

        func stableID(_ module: PCCModule) -> String {
            if let id = module.rawAttributes["MARAFLOW_ID"], !id.isEmpty { return id }
            // FNV-1a over the page/name/id gives a stable UUID-shaped id for modules that have no Maraflow one.
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in "\(module.page)|\(module.name)|\(module.id)".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            let hash2: UInt64 = hash &* 0x9e3779b97f4a7c15 &+ 0x517cc1b727220a95
            func hex(_ value: UInt64) -> String { String(format: "%016llX", value) }
            let text = hex(hash) + hex(hash2)
            let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            let parts = ranges.map { range -> String in
                let start = text.index(text.startIndex, offsetBy: range.lowerBound)
                let end = text.index(text.startIndex, offsetBy: range.upperBound)
                return String(text[start..<end])
            }
            return parts.joined(separator: "-")
        }

        for pageIndex in 0..<project.pages.count {
            let page = project.pages[pageIndex]
            let modules = project.modules.filter { $0.page == page.caption }
            let stModule = modules.first { $0.guid == MaraflowStPage.guid }
            let ldModule = modules.first { $0.guid == MaraflowLdPage.guid }
            let language: String
            if stModule != nil { language = "ST" }
            else if ldModule != nil { language = "LD" }
            else { language = properties["page.\(pageIndex).language"] ?? "FBD" }
            put("page.\(pageIndex).name", page.caption)
            put("page.\(pageIndex).language", language)
            if let stModule {
                put("page.\(pageIndex).stCode", stModule.rawAttributes["MARAFLOW_ST_CODE"] ?? "")
                put("page.\(pageIndex).stThreadId", "\(stModule.threadId)")
                put("page.\(pageIndex).stOrder", "\(stModule.order)")
            }

            if language == "LD" {
                // The preserved rung table is the LD page's source of truth; block/wire overlays do not apply.
                put("page.\(pageIndex).blockCount", "0")
                put("page.\(pageIndex).wireCount", "0")
                continue
            }
            if language == "ST" {
                put("page.\(pageIndex).blockCount", "0")
                put("page.\(pageIndex).wireCount", "0")
                continue
            }

            var blockIndex = 0
            var localIDs: [Int: String] = [:]
            for module in modules {
                let definition = MaraflowCatalog.definition(forGuid: module.guid)
                let macroName = MacroCalls.target(of: module)
                let isInterface = module.guid == InputsBlock.guid
                var defID: String?
                var typeName = module.name
                var bridgeMap: Bridge?
                var bridgeDefinition: MaraflowDefinition?
                if isInterface {
                    let kind = (module.rawAttributes["MACRO_NAME"] ?? "").lowercased()
                    if kind == "inputs" {
                        defID = "Macro.MacroIn"
                        typeName = "MacroIn"
                    } else if kind == "outputs" {
                        defID = "Macro.MacroOut"
                        typeName = "MacroOut"
                    }
                } else if let definition {
                    defID = definition.id
                    typeName = definition.typeName
                } else if let macroName {
                    defID = "Macro.User.\(macroName)"
                    typeName = macroName
                } else if let info = BlockTypeCatalog.info(forGuid: module.guid),
                          let candidate = Self.bridge(for: info),
                          let definition = MaraflowCatalog.byId[candidate.definitionId] {
                    defID = definition.id
                    typeName = definition.typeName
                    bridgeMap = candidate
                    bridgeDefinition = definition
                }
                guard let defID else {
                    notes.append("Block '\(module.name)' has no Maraflow representation and was not exported.")
                    continue
                }
                let id = stableID(module)
                localIDs[module.id] = id
                exportedID[module.id] = id
                let prefix = "page.\(pageIndex).block.\(blockIndex)."
                blockIndex += 1
                put(prefix + "id", id)
                put(prefix + "defId", defID)
                put(prefix + "typeName", typeName)
                put(prefix + "name", module.name)
                put(prefix + "gridX", "\(Int((module.x / 32).rounded()))")
                put(prefix + "gridY", "\(Int((module.y / 32).rounded()))")
                put(prefix + "threadId", "\(module.threadId)")
                put(prefix + "order", "\(module.order)")
                put(prefix + "color", module.rawAttributes["MARAFLOW_COLOR"] ?? "clDefault")
                put(prefix + "description", module.rawAttributes["MARAFLOW_DESCRIPTION"] ?? "")
                var propIndex = 0
                for (key, value) in module.rawAttributes where key.hasPrefix("MARAFLOW_PROP_") {
                    put(prefix + "prop.\(propIndex).k", String(key.dropFirst("MARAFLOW_PROP_".count)))
                    put(prefix + "prop.\(propIndex).v", value)
                    propIndex += 1
                }
                put(prefix + "propCount", "\(propIndex)")

                if let bridgeMap, let bridgeDefinition {
                    // A Dirigo block's pins are re-ordered onto the Maraflow definition's own pin table.
                    put(prefix + "inCount", "\(bridgeDefinition.inputs.count)")
                    for (index, spec) in bridgeDefinition.inputs.enumerated() {
                        let source = bridgeMap.inputs[index] ?? index
                        let pin = module.inPins.indices.contains(source) ? module.inPins[source] : nil
                        let pinPrefix = prefix + "in.\(index)."
                        put(pinPrefix + "short", spec.abbrev)
                        put(pinPrefix + "full", spec.name)
                        put(pinPrefix + "type", spec.dataType.uppercased())
                        put(pinPrefix + "const", pin?.value.description ?? spec.defaultValue)
                    }
                    put(prefix + "outCount", "\(bridgeDefinition.outputs.count)")
                    for (index, spec) in bridgeDefinition.outputs.enumerated() {
                        let source = bridgeMap.outputs[index] ?? index
                        let pin = module.outPins.indices.contains(source) ? module.outPins[source] : nil
                        let pinPrefix = prefix + "out.\(index)."
                        put(pinPrefix + "short", spec.abbrev)
                        put(pinPrefix + "full", spec.name)
                        put(pinPrefix + "type", spec.dataType.uppercased())
                        put(pinPrefix + "const", pin?.value.description ?? spec.defaultValue)
                    }
                } else {
                    put(prefix + "inCount", "\(module.inPins.count)")
                    for (index, pin) in module.inPins.enumerated() {
                        let pinPrefix = prefix + "in.\(index)."
                        put(pinPrefix + "short", pin.name ?? "X\(index)")
                        put(pinPrefix + "full", pin.name ?? "Input \(index)")
                        put(pinPrefix + "type", pinType(definition: definition, index: index, output: false,
                                                       fallback: pin.value))
                        put(pinPrefix + "const", pin.value.description)
                    }
                    put(prefix + "outCount", "\(module.outPins.count)")
                    for (index, pin) in module.outPins.enumerated() {
                        let pinPrefix = prefix + "out.\(index)."
                        put(pinPrefix + "short", pin.name ?? "Y\(index)")
                        put(pinPrefix + "full", pin.name ?? "Output \(index)")
                        put(pinPrefix + "type", pinType(definition: definition, index: index, output: true,
                                                       fallback: pin.value))
                        put(pinPrefix + "const", pin.value.description)
                    }
                }
            }
            put("page.\(pageIndex).blockCount", "\(blockIndex)")

            var wireIndex = 0
            for connection in project.inConnections + project.paramConnections {
                guard let source = localIDs[connection.outModuleId],
                      let target = localIDs[connection.inModuleId] else { continue }
                let prefix = "page.\(pageIndex).wire.\(wireIndex)."
                wireIndex += 1
                put(prefix + "netName", connection.rawAttributes["MARAFLOW_NET"] ?? "")
                put(prefix + "customNetName", connection.rawAttributes["MARAFLOW_NET"] == nil ? "false" : "true")
                put(prefix + "srcBlock", source)
                put(prefix + "srcPin", "\(connection.outPinId)")
                put(prefix + "dstBlock", target)
                put(prefix + "dstPin", "\(connection.inPinId)")
                put(prefix + "hidden", connection.rawAttributes["MARAFLOW_HIDDEN"] ?? "false")
                put(prefix + "busId", connection.rawAttributes["MARAFLOW_BUS"] ?? "")
                put(prefix + "points", "")
            }
            put("page.\(pageIndex).wireCount", "\(wireIndex)")
        }

        let data = propertiesXML(properties)
        return MaraflowExportResult(data: data, notes: notes)
    }

    /// Java `Properties.storeToXML` shape, sorted for a deterministic file.
    static func propertiesXML(_ properties: [String: String]) -> Data {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
        <properties>
        <comment>Maraflow PLC Project (.mfl)</comment>

        """
        for key in properties.keys.sorted() {
            xml += "<entry key=\"\(escape(key))\">\(escape(properties[key] ?? ""))</entry>\n"
        }
        xml += "</properties>\n"
        return Data(xml.utf8)
    }
}
