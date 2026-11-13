import Foundation
import WirebenchCore
import WirebenchLibrary

/// Imports a Maraflow `.mfl` project into the Wirebench model.
///
/// Maraflow's sheet model is close enough to import directly: pages hold blocks with UUID ids and wires name a source
/// and target pin. Blocks whose definition has a close Wirebench counterpart are mapped to it; the rest become inert
/// `Unresolved` placeholders with the same pins, so the topology survives and the approximation is visible instead of
/// silently running different logic. Ladder and Structured Text pages are kept as empty pages with a note.
public struct MaraflowImporter {
    public struct Outcome {
        public let project: PCCProject
        public let notes: [String]
    }

    private struct Mapping {
        var target: String
        /// Maraflow input index -> Wirebench input index. Empty means by position.
        var inputs: [Int: Int] = [:]
        /// Maraflow input index -> Wirebench parameter index.
        var params: [Int: Int] = [:]
        /// Maraflow output index -> Wirebench output index. Empty means by position.
        var outputs: [Int: Int] = [:]
        /// Outputs whose logical value is inverted (Nand, Nor, Xnor, Ne, Ge, Le).
        var invertedOutputs: Set<Int> = []
        /// Target inputs that Maraflow has no pin for but which must be live for the block to run (PulseGen's Act).
        var inputConstants: [Int: PinValue] = [:]
        var note: String?

        static func identity(_ target: String, note: String? = nil) -> Mapping {
            Mapping(target: target, note: note)
        }
    }

    private struct Placed {
        let moduleId: Int
        let mapping: Mapping?
    }

    public static func importProject(at url: URL) throws -> Outcome {
        try importProject(data: Data(contentsOf: url), filename: url.deletingPathExtension().lastPathComponent)
    }

    public static func importProject(data: Data, filename: String) throws -> Outcome {
        let document = try MaraflowDocument(data: data)
        let maraflow = try MaraflowProject.read(document, filename: filename)

        var project = PCCProject(name: maraflow.name.isEmpty ? filename : maraflow.name)
        project.application = "Maraflow"
        if !maraflow.version.isEmpty { project.applicationVersion = maraflow.version }
        project.author = maraflow.author
        project.description = maraflow.description
        project.rawAttributes["MARAFLOW_TARGET"] = maraflow.target
        project.rawAttributes["MARAFLOW_VERSION"] = maraflow.version

        var notes: [String] = []
        var unsupported: [String: Int] = [:]
        var approximated: [String: Int] = [:]
        var importedBlocks = 0
        var importedWires = 0
        var nextModuleId = 1
        var usedPageNames: Set<String> = []

        for page in maraflow.pages {
            var caption = page.cleanName
            if usedPageNames.contains(caption.lowercased()) {
                var suffix = 2
                while usedPageNames.contains("\(caption) \(suffix)".lowercased()) { suffix += 1 }
                caption += " \(suffix)"
            }
            usedPageNames.insert(caption.lowercased())
            project.pages.append(ProjectPage(caption: caption))

            if page.language == "ST" && page.stCode.isEmpty {
                notes.append("Page '\(caption)' is Structured Text; its source is not represented on the sheet.")
            } else if page.language == "ST" {
                notes.append("Page '\(caption)' is Structured Text; the imported page is empty (the source is not converted).")
            }
            if page.rungCount > 0 {
                notes.append("Page '\(caption)' has \(page.rungCount) ladder rung(s); ladder logic is not imported.")
            }
            if page.graphicCount > 0 {
                notes.append("Page '\(caption)' has \(page.graphicCount) graphic element(s); graphics are not imported.")
            }
            if page.isMacro {
                notes.append("Macro page '\(caption)' is imported as a normal page; calls to it become inert placeholders.")
            }

            var placed: [String: Placed] = [:]
            for block in page.blocks {
                let id = nextModuleId
                nextModuleId += 1
                let mapping = mappings[block.definitionId]
                let module: PCCModule
                if let mapping, BlockTypeCatalog.info(forBlockName: mapping.target) != nil {
                    module = mappedModule(block, mapping: mapping, id: id, page: caption,
                                          approximated: &approximated)
                } else {
                    module = placeholderModule(block, id: id, page: caption,
                                               unsupported: &unsupported)
                }
                project.modules.append(module)
                placed[block.id] = Placed(moduleId: id, mapping: mapping)
                importedBlocks += 1
            }

            for wire in page.wires {
                guard let source = placed[wire.sourceBlock], let target = placed[wire.targetBlock] else {
                    notes.append("A wire on '\(caption)' refers to a block that is not in the file.")
                    continue
                }
                guard let module = project.modules.first(where: { $0.id == source.moduleId }),
                      let targetModule = project.modules.first(where: { $0.id == target.moduleId }) else { continue }
                let sourceIndex = mappedIndex(wire.sourcePin, in: source.mapping?.outputs,
                                              available: module.outPins.count)
                guard let sourceIndex else {
                    notes.append("A wire on '\(caption)' leaves an output that has no Wirebench counterpart.")
                    continue
                }
                var targetInput: Int?
                var isParam = false
                if let param = target.mapping?.params[wire.targetPin], param < targetModule.paramPins.count {
                    targetInput = param
                    isParam = true
                } else if let input = mappedIndex(wire.targetPin, in: target.mapping?.inputs,
                                                  available: targetModule.inPins.count) {
                    targetInput = input
                }
                guard let targetInput else {
                    notes.append("A wire on '\(caption)' enters an input that has no Wirebench counterpart.")
                    continue
                }
                if !isParam, source.mapping?.invertedOutputs.contains(wire.sourcePin) == true,
                   targetModule.inPins.indices.contains(targetInput) {
                    project.modules[project.modules.firstIndex(where: { $0.id == target.moduleId })!]
                        .inPins[targetInput].inverted = true
                }
                let error = project.connect(outModuleId: source.moduleId, outPinId: sourceIndex,
                                            toModuleId: target.moduleId, inPinId: targetInput,
                                            toParam: isParam)
                if let error {
                    notes.append("A wire on '\(caption)' could not be connected (\(error)).")
                } else {
                    importedWires += 1
                    if wire.hidden {
                        notes.append("A hidden wire on '\(caption)' is imported as a normal wire.")
                    }
                }
            }
        }

        notes.insert("Imported \(maraflow.pages.count) page(s), \(importedBlocks) block(s) and \(importedWires) wire(s) from Maraflow.", at: 0)
        if !maraflow.target.isEmpty {
            notes.append("Maraflow target '\(maraflow.target)' has no Wirebench profile; the default profile is used.")
        }
        if !unsupported.isEmpty {
            let types = unsupported.keys.sorted().map { "\($0) (\(unsupported[$0]!))" }.joined(separator: ", ")
            notes.append("\(unsupported.values.reduce(0, +)) block(s) have no close Wirebench equivalent and are inert placeholders: \(types).")
        }
        if !approximated.isEmpty {
            let types = approximated.keys.sorted().joined(separator: ", ")
            notes.append("Approximated: \(types).")
        }
        return Outcome(project: project, notes: notes)
    }

    /// A mapping is by position unless the table names an index; an index the table does not name is not connected,
    /// so a block with more pins than its Wirebench counterpart drops only the pins that have no meaning there.
    private static func mappedIndex(_ index: Int, in map: [Int: Int]?, available: Int) -> Int? {
        let target = map?.isEmpty == false ? map?[index] : index
        guard let target, target >= 0, target < available else { return nil }
        return target
    }

    private static func mappedModule(_ block: MaraflowBlock, mapping: Mapping, id: Int, page: String,
                                     approximated: inout [String: Int]) -> PCCModule {
        let guid = BlockTypeCatalog.info(forBlockName: mapping.target)!.guid
        var module = BlockFactory.makeModule(guid: guid, id: id, name: block.name, x: Double(block.gridX * 32),
                                             y: Double(block.gridY * 32), order: block.order,
                                             threadId: block.threadId, page: page)
        module.rawAttributes["MARAFLOW_DEF"] = block.definitionId
        module.rawAttributes["MARAFLOW_TYPE"] = block.typeName
        module.rawAttributes["MARAFLOW_ID"] = block.id
        if !block.description.isEmpty { module.rawAttributes["MARAFLOW_DESCRIPTION"] = block.description }
        for (key, value) in block.properties {
            // Attribute names have to be valid XML for the legacy export, so keep only name characters.
            let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            module.rawAttributes["MARAFLOW_PROP_\(safe)"] = value
        }

        for (sourceIndex, pin) in block.inputs.enumerated() {
            if let targetIndex = mappedIndex(sourceIndex, in: mapping.inputs, available: module.inPins.count) {
                module.inPins[targetIndex].value = value(for: pin)
                if !pin.short.isEmpty { module.inPins[targetIndex].name = pin.short }
            } else if let targetIndex = mapping.params[sourceIndex], targetIndex < module.paramPins.count {
                module.paramPins[targetIndex].value = value(for: pin)
                if !pin.short.isEmpty { module.paramPins[targetIndex].name = pin.short }
            }
        }
        for (sourceIndex, pin) in block.outputs.enumerated() {
            if let targetIndex = mappedIndex(sourceIndex, in: mapping.outputs, available: module.outPins.count) {
                module.outPins[targetIndex].value = value(for: pin)
                if !pin.short.isEmpty { module.outPins[targetIndex].name = pin.short }
            }
        }
        if mapping.invertedOutputs.isEmpty == false {
            approximated["\(block.typeName) (inverted output)", default: 0] += 1
        }
        for (index, value) in mapping.inputConstants where module.inPins.indices.contains(index) {
            module.inPins[index].value = value
        }
        if let note = mapping.note { approximated[note, default: 0] += 1 }
        return module
    }

    private static func placeholderModule(_ block: MaraflowBlock, id: Int, page: String,
                                          unsupported: inout [String: Int]) -> PCCModule {
        unsupported[block.typeName.isEmpty ? block.definitionId : block.typeName, default: 0] += 1
        let guid = BlockTypeCatalog.info(forBlockName: "Unresolved")!.guid
        let inPins = block.inputs.enumerated().map {
            Pin(id: $0.offset, value: value(for: $0.element), rights: 0, name: $0.element.short)
        }
        let outPins = block.outputs.enumerated().map {
            Pin(id: $0.offset, value: value(for: $0.element), rights: 2, name: $0.element.short)
        }
        return PCCModule(id: id, guid: guid, name: block.name, x: Double(block.gridX * 32),
                         y: Double(block.gridY * 32), order: block.order, threadId: block.threadId,
                         page: page, inPins: inPins, paramPins: [], outPins: outPins,
                         rawAttributes: AttributeBag([("MARAFLOW_DEF", block.definitionId),
                                                      ("MARAFLOW_TYPE", block.typeName),
                                                      ("MARAFLOW_ID", block.id)]),
                         rawChildren: [])
    }

    private static func value(for pin: MaraflowPin) -> PinValue {
        switch pin.type {
        case "BOOL":
            return .bool(pin.constant == "1" || pin.constant.lowercased() == "true")
        case "FLOAT":
            return .float(Float(pin.constant) ?? 0)
        case "LONG":
            return .int64(parseInteger(pin.constant))
        default:
            return .int32(Int32(clamping: parseInteger(pin.constant)))
        }
    }

    private static func parseInteger(_ string: String) -> Int64 {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return Int64(trimmed.dropFirst(2), radix: 16) ?? 0 }
        if trimmed.lowercased().hasPrefix("0b") { return Int64(trimmed.dropFirst(2), radix: 2) ?? 0 }
        return Int64(trimmed) ?? 0
    }

    private static let mappings: [String: Mapping] = {
        var table: [String: Mapping] = [:]
        func add(_ id: String, _ mapping: Mapping) { table[id] = mapping }
        for name in ["And", "Or", "Xor", "Not", "RS"] {
            add("Bool." + name, .identity(name))
        }
        add("Bool.Nand", Mapping(target: "And", invertedOutputs: [0]))
        add("Bool.Nor", Mapping(target: "Or", invertedOutputs: [0]))
        add("Bool.Xnor", Mapping(target: "Xor", invertedOutputs: [0]))
        add("Bool.SR", Mapping(target: "RS", note: "SR mapped to RS (reset dominates in Wirebench's RS)"))

        for (source, target) in [("Add", "IAdd"), ("Sub", "ISub"), ("Mul", "IMul")] {
            add("Math." + source, .identity(target))
        }
        add("Math.Div", Mapping(target: "Div", outputs: [0: 0], note: "Math.Div mapped to Div (Err dropped)"))
        add("Math.Abs", .identity("IAbs"))
        add("Math.Neg", .identity("INeg"))
        add("Math.Sqrt", Mapping(target: "FSqrt", inputs: [0: 0, 1: 1], outputs: [0: 0]))
        add("Math.Sin", Mapping(target: "FSin", inputs: [0: 0, 1: 1], outputs: [0: 0]))
        add("Math.Cos", Mapping(target: "FCos", inputs: [0: 0, 1: 1], outputs: [0: 0]))

        func comparator(_ id: String, output: Int, inverted: Bool = false) {
            let mapping = Mapping(target: "Comparator", inputs: [0: 0, 1: 1, 2: 2],
                                  outputs: [0: output], invertedOutputs: inverted ? [0] : [])
            add(id, mapping)
        }
        comparator("Main.Comparators.EQ", output: 1)
        comparator("Main.Comparators.NE", output: 1, inverted: true)
        comparator("Main.Comparators.GT", output: 0)
        comparator("Main.Comparators.GE", output: 2, inverted: true)
        comparator("Main.Comparators.LT", output: 2)
        comparator("Main.Comparators.LE", output: 0, inverted: true)
        add("Main.Comparators.InRange", Mapping(target: "InRange", params: [2: 0, 3: 1],
                                                note: "InRange Min/Max mapped to its Low/High parameters"))

        add("Main.Conversion.PackBits", Mapping(target: "Bits2Int", inputs: [0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7, 8: 8], outputs: [0: 0]))
        add("Main.Conversion.UnpackBits", Mapping(target: "Int2Bits", inputs: [1: 0], outputs: [0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7],
                                                  note: "UnpackBits mapped to Int2Bits (En dropped)"))
        add("Main.Switches.Sel", Mapping(target: "ISwitch", inputs: [0: 0, 1: 1, 2: 2, 3: 3]))
        add("Main.Switches.Demux", Mapping(target: "IDemux", inputs: [0: 0, 1: 1, 2: 2]))

        add("IO.8xDI", .identity("8xDI"))
        add("IO.8xDO", .identity("8xDO"))
        add("IO.DI", Mapping(target: "8xDI", outputs: [0: 0]))
        add("IO.DO", Mapping(target: "8xDO", inputs: [0: 0, 1: 1], outputs: [0: 0]))
        add("IO.AI", Mapping(target: "8xAI", outputs: [0: 0]))

        add("Main.Timers.Timer", Mapping(target: "Timer", inputs: [0: 0, 1: 1], params: [2: 0],
                                         outputs: [0: 0, 1: 1],
                                         note: "Timer PT mapped to Dly; Q/ET to the timer outputs"))
        add("Main.Timers.SinglePulse", Mapping(target: "SinglePulse", inputs: [0: 0, 1: 1], outputs: [0: 1],
                                               note: "SinglePulse In mapped to Tr; TOn defaults to one cycle"))
        add("Main.Timers.PulseGen", Mapping(target: "PulseGen", inputs: [0: 0], params: [1: 0, 2: 1],
                                            outputs: [0: 1], inputConstants: [1: .bool(true)],
                                            note: "PulseGen runs with Act held true; THi/TLo to TOn/TOff"))
        add("Main.Filters.Debounce", Mapping(target: "DelayFilter", inputs: [0: 0, 1: 1], params: [2: 0],
                                             outputs: [0: 1],
                                             note: "Debounce mapped to DelayFilter (Tms counts cycles)"))
        add("Main.Timers.DecodeDate", Mapping(target: "DecodeDate", inputs: [0: 0, 1: 1],
                                              outputs: [0: 2, 1: 1, 2: 0],
                                              note: "DecodeDate keeps date fields; hour/minute/second are dropped"))
        add("Main.Timers.EncodeDate", Mapping(target: "EncodeDate", inputs: [0: 0, 1: 3, 2: 2, 3: 1],
                                              outputs: [0: 0],
                                              note: "EncodeDate keeps date fields; time fields are dropped"))
        add("IO.AO", Mapping(target: "2xAO", inputs: [0: 0, 1: 1], outputs: [0: 0],
                             note: "AO drives channel 0 of 2xAO; its Ok output is dropped"))
        add("IO.Encoder", Mapping(target: "IRC", inputs: [0: 0, 1: 1], outputs: [0: 0, 1: 1],
                                  note: "Encoder mapped to IRC; Vel lands on Null"))
        add("Visual.Segment", .identity("Segment"))
        add("Visual.Value", Mapping(target: "Value", inputs: [0: 0]))
        add("Visual.Vars.BoolVar", Mapping(target: "BoolVar", outputs: [0: 0]))
        add("Visual.Vars.IntVar", Mapping(target: "IntVar", outputs: [0: 0]))
        add("Visual.Vars.LongVar", Mapping(target: "LongVar", outputs: [0: 0]))
        return table
    }()
}
