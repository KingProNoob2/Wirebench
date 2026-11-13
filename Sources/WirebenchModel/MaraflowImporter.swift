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
        /// The raw `.mfl` properties, preserved on the project as `maraflow` extras.
        public let properties: [String: String]
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

        for (pageIndex, page) in maraflow.pages.enumerated() {
            var caption = page.isMacro ? "*" + page.cleanName : page.cleanName
            if usedPageNames.contains(caption.lowercased()) {
                var suffix = 2
                while usedPageNames.contains("\(caption) #\(suffix)".lowercased()) { suffix += 1 }
                caption += " #\(suffix)"
            }
            usedPageNames.insert(caption.lowercased())
            project.pages.append(ProjectPage(caption: caption))

            if page.language == "ST" {
                project.modules.append(stPageModule(page, caption: caption, id: nextModuleId))
                nextModuleId += 1
                notes.append("Page '\(caption)' is Structured Text; it runs through the native ST interpreter.")
            }
            if !page.rungs.isEmpty {
                let groups = Dictionary(grouping: page.rungs, by: \.threadID)
                for thread in groups.keys.sorted() {
                    project.modules.append(ldPageModule(page, caption: caption, rungs: groups[thread]!,
                                                        thread: thread, order: pageIndex,
                                                        id: nextModuleId))
                    nextModuleId += 1
                }
                notes.append("Page '\(caption)': \(page.rungs.count) ladder rung(s) run through the native ladder evaluator.")
            }
            if !page.graphics.isEmpty {
                let count = importGraphics(page.graphics, page: caption, project: &project)
                notes.append("Page '\(caption)': imported \(count) graphic object(s).")
            }
            if page.isMacro {
                notes.append("Macro page '\(caption)' is imported as a macro sheet.")
            }

            var placed: [String: Placed] = [:]
            for block in page.blocks {
                let id = nextModuleId
                nextModuleId += 1
                let mapping = mappings[block.definitionId]
                var placementMapping = mapping
                let module: PCCModule
                if block.definitionId == "Macro.MacroIn" {
                    module = macroInterface(block, kind: .inputs, id: id, page: caption)
                } else if block.definitionId == "Macro.MacroOut" {
                    module = macroInterface(block, kind: .outputs, id: id, page: caption)
                } else if block.definitionId.hasPrefix("Macro.User.") {
                    module = macroCall(block, id: id, page: caption)
                } else if let definition = MaraflowCatalog.byId[block.definitionId],
                          MaraflowCatalog.ported.contains(definition.id) {
                    module = nativeModule(block, definition: definition, id: id, page: caption)
                    placementMapping = nil
                } else if let mapping, BlockTypeCatalog.info(forBlockName: mapping.target) != nil {
                    module = mappedModule(block, mapping: mapping, id: id, page: caption,
                                          approximated: &approximated)
                } else {
                    module = placeholderModule(block, id: id, page: caption,
                                               unsupported: &unsupported)
                }
                project.modules.append(module)
                placed[block.id] = Placed(moduleId: id, mapping: placementMapping)
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
        if let version = maraflow.version.isEmpty ? nil : maraflow.version {
            project.maraflow = MaraflowExtras(formatVersion: version, properties: document.values)
        } else {
            project.maraflow = MaraflowExtras(properties: document.values)
        }
        return Outcome(project: project, notes: notes, properties: document.values)
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

    /// A native Maraflow block: exact definition pins, no approximation through a Dirigo type.
    private static func nativeModule(_ block: MaraflowBlock, definition: MaraflowDefinition,
                                     id: Int, page: String) -> PCCModule {
        var module = BlockFactory.makeModule(guid: definition.guid, id: id, name: block.name,
                                             x: Double(block.gridX * 32), y: Double(block.gridY * 32),
                                             order: block.order, threadId: block.threadId, page: page)
        module.rawAttributes["MARAFLOW_DEF"] = definition.id
        module.rawAttributes["MARAFLOW_TYPE"] = block.typeName
        module.rawAttributes["MARAFLOW_ID"] = block.id
        if !block.description.isEmpty { module.rawAttributes["MARAFLOW_DESCRIPTION"] = block.description }
        for (key, value) in block.properties {
            let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            module.rawAttributes["MARAFLOW_PROP_\(safe)"] = value
        }
        for (index, pin) in block.inputs.enumerated() where index < module.inPins.count {
            module.inPins[index].value = value(for: pin)
            if !pin.short.isEmpty { module.inPins[index].name = pin.short }
        }
        for (index, pin) in block.outputs.enumerated() where index < module.outPins.count {
            module.outPins[index].value = value(for: pin)
            if !pin.short.isEmpty { module.outPins[index].name = pin.short }
        }
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

    /// Map Maraflow's graphic objects onto the native shape/text model so they appear on the canvas.
    private static func importGraphics(_ graphics: [MaraflowGraphic], page: String,
                                       project: inout PCCProject) -> Int {
        func colour(_ rgb: Int) -> String {
            String(format: "#%06X", rgb & 0xFFFFFF)
        }
        var count = 0
        for graphic in graphics {
            let x = Double(graphic.gridX * 32)
            let y = Double(graphic.gridY * 32)
            let width = Double(max(1, graphic.gridW) * 32)
            let height = Double(max(1, graphic.gridH) * 32)
            let kind = graphic.kind.uppercased()
            if kind.contains("TEXT") {
                project.graphics.append(ProjectGraphic(type: 4, page: page, text: graphic.text,
                                                       nodes: [RoutePoint(x: x, y: y)],
                                                       penColor: colour(graphic.strokeRgb),
                                                       fontName: "Arial", fontSize: graphic.fontSize,
                                                       fontColor: colour(graphic.strokeRgb)))
            } else if kind.contains("LINE") {
                project.graphics.append(ProjectGraphic(type: 1, page: page,
                                                       nodes: [RoutePoint(x: x, y: y),
                                                               RoutePoint(x: x + width, y: y + height)],
                                                       penColor: colour(graphic.strokeRgb),
                                                       penStyle: graphic.dashed ? 1 : 0,
                                                       penWidth: graphic.strokeWidth))
            } else {
                let ellipse = kind.contains("ELLIPSE") || kind.contains("CIRCLE")
                project.graphics.append(ProjectGraphic(
                    type: ellipse ? 3 : 2, page: page,
                    text: graphic.text.isEmpty ? nil : graphic.text,
                    nodes: [RoutePoint(x: x, y: y), RoutePoint(x: x + width, y: y + height)],
                    penColor: colour(graphic.strokeRgb),
                    penStyle: graphic.dashed ? 1 : 0,
                    penWidth: graphic.strokeWidth,
                    brushColor: graphic.filled ? colour(graphic.fillRgb) : nil,
                    brushStyle: graphic.filled ? 1 : 0))
            }
            count += 1
        }
        return count
    }

    /// One ladder page's rungs for one thread become one no-pin native block. Rungs on other threads are in their
    /// own module, so the core's scheduler reproduces Maraflow's per-thread rung order.
    private static func ldPageModule(_ page: MaraflowPage, caption: String, rungs: [MaraflowRung],
                                     thread: Int, order: Int, id: Int) -> PCCModule {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "\u{1F}", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        func typeCode(_ type: String) -> Int {
            switch type.uppercased() {
            case "BOOL", "BOOLEAN", "BIT": return 0
            case "LONG", "LINT", "INT64": return 2
            case "FLOAT", "REAL": return 3
            default: return 1
            }
        }
        func elementLine(_ tag: String, _ element: MaraflowLadderElement) -> String {
            var line = "\(tag)\u{1F}\(clean(element.kind))\u{1F}\(clean(element.operand))\u{1F}\(clean(element.sourceOperand))\n"
            guard element.kind == "FUNCTION_BLOCK", let block = element.block,
                  let definition = MaraflowCatalog.byId[block.definitionId],
                  let variant = MaraflowCatalog.all.firstIndex(where: { $0.id == definition.id })
            else { return line }
            let hasEnable = block.inputs.first?.short.lowercased() == "en"
            line += "F\u{1F}\(variant)\u{1F}\(block.inputs.count)\u{1F}\(block.outputs.count)\u{1F}\(hasEnable ? 1 : 0)\n"
            for pin in block.inputs {
                line += "I\u{1F}\(typeCode(pin.type))\u{1F}\(clean(pin.constant))\n"
            }
            for pin in block.outputs {
                line += "O\u{1F}\(typeCode(pin.type))\u{1F}\(clean(pin.constant))\n"
            }
            return line
        }
        var text = ""
        for rung in rungs.sorted(by: { $0.order < $1.order }) {
            text += "R\u{1F}\(rung.order)\n"
            for element in rung.main {
                text += elementLine("M", element)
            }
            for branch in rung.branches {
                text += "B\u{1F}\(branch.start)\u{1F}\(branch.end)\n"
                for element in branch.elements {
                    text += elementLine("E", element)
                }
            }
            for coil in rung.coils {
                text += elementLine("C", coil)
            }
        }
        return PCCModule(id: id, guid: MaraflowLdPage.guid, name: "LD \(caption) T\(thread)",
                         x: 32, y: 32, order: order, threadId: thread, page: caption,
                         inPins: [], paramPins: [], outPins: [],
                         rawAttributes: AttributeBag([("MARAFLOW_LD_RUNGS", text)]))
    }

    /// One Structured Text page becomes one native block with no pins; the core compiles and runs its code each scan.
    private static func stPageModule(_ page: MaraflowPage, caption: String, id: Int) -> PCCModule {
        var code = page.stCode
        if !page.stVariables.isEmpty, !code.uppercased().contains("VAR") {
            let declarations = page.stVariables.map { variable in
                "\(variable.name) : \(variable.type) := \(variable.initial);"
            }.joined(separator: "\n")
            code = "VAR\n\(declarations)\nEND_VAR\n" + code
        }
        return PCCModule(id: id, guid: MaraflowStPage.guid, name: "ST \(caption)",
                         x: 32, y: 32, order: page.stOrder, threadId: page.stThreadID, page: caption,
                         inPins: [], paramPins: [], outPins: [],
                         rawAttributes: AttributeBag([("MARAFLOW_ST_CODE", code)]))
    }

    // MARK: - Ladder pages

    private enum LadderSource {
        case constant(Bool)
        case pin(module: Int, pin: Int)
    }

    /// Converts the simple rung shape — series NO/NC contacts on `DI0…DI7` driving NO/negated coils on
    /// `DO0…DO7` — into an 8xDI, logic blocks and an 8xDO. Parallel branches, function blocks, edge contacts and
    /// latching/analog coils are reported and left out; partial rung semantics would be worse than none.
    private static func importLadderPage(_ page: MaraflowPage, caption: String, project: inout PCCProject,
                                         nextId: inout Int, notes: inout [String]) {
        var diModule: Int?
        var doModule: Int?
        var order = 10

        func addModule(_ guid: UUID, name: String, x: Double, y: Double, moduleOrder: Int) -> Int {
            let id = nextId
            nextId += 1
            var module = BlockFactory.makeModule(guid: guid, id: id, name: name, x: x, y: y,
                                                 order: moduleOrder, threadId: page.stThreadID, page: caption)
            if !module.inPins.isEmpty {
                module.inPins[0].value = .bool(true)
            }
            project.modules.append(module)
            return id
        }

        func sharedDI() -> Int {
            if let diModule { return diModule }
            let id = addModule(BlockTypeCatalog.info(forBlockName: "8xDI")!.guid, name: "DI",
                               x: 32, y: 32, moduleOrder: 1)
            diModule = id
            return id
        }

        func sharedDO() -> Int {
            if let doModule { return doModule }
            let id = addModule(BlockTypeCatalog.info(forBlockName: "8xDO")!.guid, name: "DO",
                               x: 224, y: 32, moduleOrder: 100_000)
            doModule = id
            return id
        }

        func wire(_ source: LadderSource, to module: Int, pin: Int) {
            switch source {
            case .constant(let value):
                if let index = project.modules.firstIndex(where: { $0.id == module }),
                   project.modules[index].inPins.indices.contains(pin) {
                    project.modules[index].inPins[pin].value = .bool(value)
                }
            case .pin(let sourceModule, let sourcePin):
                project.connect(outModuleId: sourceModule, outPinId: sourcePin, toModuleId: module, inPinId: pin)
            }
        }

        func invert(_ source: LadderSource) -> LadderSource {
            let id = addModule(BlockTypeCatalog.info(forBlockName: "Not")!.guid,
                               name: "LadderNot\(nextId)", x: 32, y: 200, moduleOrder: order)
            order += 10
            wire(source, to: id, pin: 1)
            return .pin(module: id, pin: 0)
        }

        for rung in page.rungs {
            guard rung.branches.isEmpty else {
                notes.append("Ladder page '\(caption)': a rung with parallel branches was skipped.")
                continue
            }
            if rung.main.contains(where: { $0.kind == "FUNCTION_BLOCK" }) {
                notes.append("Ladder page '\(caption)': a rung with a function block was skipped.")
                continue
            }
            var condition: LadderSource?
            var unsupported = false
            for element in rung.main {
                let operand = element.operand.uppercased()
                guard operand.hasPrefix("DI"), let channel = Int(operand.dropFirst(2)), (0...7).contains(channel) else {
                    unsupported = true
                    break
                }
                let source: LadderSource = .pin(module: sharedDI(), pin: channel)
                var contact: LadderSource?
                switch element.kind {
                case "NO_CONTACT": contact = source
                case "NC_CONTACT": contact = invert(source)
                default: unsupported = true
                }
                if unsupported { break }
                guard let contact else { unsupported = true; break }
                if let accumulated = condition {
                    let id = addModule(BlockTypeCatalog.info(forBlockName: "And")!.guid,
                                       name: "LadderAnd\(nextId)", x: 32, y: 32, moduleOrder: order)
                    order += 10
                    wire(accumulated, to: id, pin: 1)
                    wire(contact, to: id, pin: 2)
                    condition = .pin(module: id, pin: 0)
                } else {
                    condition = contact
                }
            }
            guard !unsupported, let condition else {
                if !unsupported {
                    notes.append("Ladder page '\(caption)': a rung without contacts was skipped.")
                } else {
                    notes.append("Ladder page '\(caption)': a rung with edge contacts or a non-DI operand was skipped.")
                }
                continue
            }
            for coil in rung.coils {
                let operand = coil.operand.uppercased()
                guard operand.hasPrefix("DO"), let channel = Int(operand.dropFirst(2)), (0...7).contains(channel) else {
                    notes.append("Ladder page '\(caption)': coil '\(coil.operand)' is not a DO channel and was skipped.")
                    continue
                }
                let outputModule = sharedDO()
                switch coil.kind {
                case "NORMAL_COIL":
                    wire(condition, to: outputModule, pin: channel + 1)
                case "NEGATED_COIL":
                    wire(invert(condition), to: outputModule, pin: channel + 1)
                default:
                    notes.append("Ladder page '\(caption)': a \(coil.kind.lowercased()) was skipped (only normal and negated coils are converted).")
                }
            }
        }
    }

    // MARK: - Structured Text pages

    private struct STVariable {
        var name: String
        var type: String
        var initial: String
    }

    private enum STOperand {
        case literal(PinValue)
        case variable(String)
    }

    private struct STCallArgument {
        var name: String?
        var operand: STOperand
    }

    /// Converts the Maraflow ST dialect's generated block-call statements into blocks and wires. It supports the
    /// declarations (`VAR…END_VAR`), `<var> := Type(args)` and `Instance(args, Out => var)` forms that the editor
    /// writes, with literal or variable arguments. General expressions and control flow are reported, not guessed.
    private static func importStPage(_ page: MaraflowPage, caption: String, project: inout PCCProject,
                                     nextId: inout Int, notes: inout [String],
                                     approximated: inout [String: Int]) {
        let parsed = stDeclarations(in: page.stCode, fallback: page.stVariables)
        var variables: [String: Int] = [:]
        var variableTypes: [String: String] = [:]
        var blockOrder = 10

        func addVariable(_ name: String, type: String, initial: String) {
            let key = name.lowercased()
            guard variables[key] == nil else { return }
            let type = stType(type)
            let guid: UUID
            switch type {
            case "BOOL": guid = BlockTypeCatalog.info(forBlockName: "BoolVar")!.guid
            case "LONG": guid = BlockTypeCatalog.info(forBlockName: "LongVar")!.guid
            case "FLOAT": guid = BlockTypeCatalog.info(forBlockName: "FloatVar")!.guid
            default: guid = BlockTypeCatalog.info(forBlockName: "IntVar")!.guid
            }
            let id = nextId
            nextId += 1
            var module = BlockFactory.makeModule(guid: guid, id: id, name: name, x: 32,
                                                 y: Double(32 + variables.count * 128), order: 1,
                                                 threadId: page.stThreadID, page: caption)
            let value = stPinValue(initial, type: type)
            module.outPins[0].value = value
            if type != "BOOL" {
                module.rawAttributes["INIT_VALUE"] = value.description
            }
            project.modules.append(module)
            variables[key] = id
            variableTypes[key] = type
        }

        for variable in parsed { addVariable(variable.name, type: variable.type, initial: variable.initial) }

        for (statement, precedingDefinition) in stStatements(page.stCode) {
            let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let call = stCall(text) else {
                if let assignment = stAssignment(text) {
                    applySTAssignment(assignment, variables: &variables, variableTypes: &variableTypes,
                                      project: &project, nextId: &nextId, caption: caption,
                                      page: page, notes: &notes)
                } else {
                    notes.append("ST page '\(caption)': a statement is not a supported block call and was skipped.")
                }
                continue
            }
            let definitionId = precedingDefinition ?? stDefinitionId(for: call.typeName) ?? ""
            let args = stArguments(call.arguments)
            let outputArgs = args.filter { $0.name == "=>" }
            let inputArgs = args.filter { $0.name != "=>" }
            guard !definitionId.isEmpty else {
                notes.append("ST page '\(caption)': block type '\(call.typeName)' is not known and was skipped.")
                continue
            }

            if definitionId.hasPrefix("Macro.User.") {
                importSTMacroCall(call, definitionId: definitionId, inputArgs: inputArgs, outputArgs: outputArgs,
                                  variables: &variables, variableTypes: &variableTypes, project: &project,
                                  nextId: &nextId, caption: caption, page: page, notes: &notes)
                continue
            }

            guard let mapping = mappings[definitionId],
                  let info = BlockTypeCatalog.info(forBlockName: mapping.target),
                  let targetTemplate = PinTemplateCatalog.template(forGuid: info.guid) else {
                notes.append("ST page '\(caption)': '\(definitionId)' has no Wirebench block and was skipped.")
                continue
            }

            var module = BlockFactory.makeModule(guid: info.guid, id: nextId, name: call.instanceName ?? call.typeName,
                                                 x: Double(32 + (variables.count % 4) * 192),
                                                 y: Double(32 + (variables.count / 4) * 160),
                                                 order: blockOrder, threadId: page.stThreadID, page: caption)
            nextId += 1
            blockOrder += 10
            module.rawAttributes["MARAFLOW_DEF"] = definitionId
            module.rawAttributes["MARAFLOW_ST"] = "1"
            project.modules.append(module)
            let moduleIndex = project.modules.count - 1

            // Calls written from the editor omit En; the maraflow definition always has it first.
            var syntheticInputs = inputArgs
            if targetTemplate.inputs.first?.abbrev.lowercased() == "en",
               !syntheticInputs.contains(where: { $0.name?.lowercased() == "en" }) {
                syntheticInputs.insert(STCallArgument(name: "En", operand: .literal(.bool(true))), at: 0)
            }
            for (index, argument) in syntheticInputs.enumerated() {
                let targetIndex: Int?
                let isParam = mapping.params[index] != nil
                if let param = mapping.params[index] {
                    targetIndex = param < module.paramPins.count ? param : nil
                } else {
                    let mapped = mapping.inputs.isEmpty ? index : mapping.inputs[index]
                    targetIndex = mapped.flatMap { $0 < module.inPins.count ? $0 : nil }
                }
                guard let targetIndex else { continue }
                switch argument.operand {
                case .literal(let value):
                    if isParam { project.modules[moduleIndex].paramPins[targetIndex].value = value }
                    else { project.modules[moduleIndex].inPins[targetIndex].value = value }
                case .variable(let name):
                    let key = name.lowercased()
                    if variables[key] == nil {
                        let type = stType(variableTypes[key] ?? "INT")
                        addVariable(name, type: type, initial: "0")
                    }
                    if let source = variables[key] {
                        if isParam {
                            project.connect(outModuleId: source, outPinId: 0, toModuleId: module.id,
                                            inPinId: targetIndex, toParam: true)
                        } else {
                            project.connect(outModuleId: source, outPinId: 0, toModuleId: module.id,
                                            inPinId: targetIndex)
                        }
                    }
                }
                if let name = argument.name, name != "En" {
                    if isParam, targetIndex < project.modules[moduleIndex].paramPins.count {
                        project.modules[moduleIndex].paramPins[targetIndex].name = name
                    } else if targetIndex < project.modules[moduleIndex].inPins.count {
                        project.modules[moduleIndex].inPins[targetIndex].name = name
                    }
                }
            }

            // Outputs: `Out => Var` in order, or the assignment target for a single-output call.
            var outputs = outputArgs
            if outputs.isEmpty, let assignmentTarget = call.assignmentTarget {
                outputs = [STCallArgument(name: "=>", operand: .variable(assignmentTarget))]
            }
            for (index, argument) in outputs.enumerated() {
                guard case .variable(let name) = argument.operand else { continue }
                let mapped = mapping.outputs.isEmpty ? index : mapping.outputs[index]
                guard let outputIndex = mapped, outputIndex < module.outPins.count else { continue }
                let outputType = targetTemplate.outputs.indices.contains(outputIndex)
                    ? targetTemplate.outputs[outputIndex].dataType : "Int"
                if variables[name.lowercased()] == nil {
                    addVariable(name, type: stType(outputType), initial: "0")
                }
                guard let variableId = variables[name.lowercased()] else { continue }
                let set = BlockFactory.makeModule(guid: SetBlock.guid, id: nextId, name: "Set_\(name)",
                                                  x: module.x + 64, y: module.y, order: blockOrder,
                                                  threadId: page.stThreadID, page: caption)
                nextId += 1
                blockOrder += 10
                project.modules.append(set)
                project.connect(outModuleId: module.id, outPinId: outputIndex, toModuleId: set.id, inPinId: 1)
                project.connect(outModuleId: variableId, outPinId: 0, toModuleId: set.id, inPinId: 2)
            }
            approximated["ST page '\(caption)'"] = 1
        }
    }

    private static func importSTMacroCall(_ call: MaraflowSTCall, definitionId: String, inputArgs: [STCallArgument],
                                          outputArgs: [STCallArgument], variables: inout [String: Int],
                                          variableTypes: inout [String: String], project: inout PCCProject,
                                          nextId: inout Int, caption: String, page: MaraflowPage,
                                          notes: inout [String]) {
        let name = String(definitionId.dropFirst("Macro.User.".count))
        let inPins = inputArgs.enumerated().map { Pin(id: $0.offset, value: stStaticValue($0.element.operand), rights: 0,
                                                      name: $0.element.name) }
        let outPins = outputArgs.enumerated().map { Pin(id: $0.offset, value: .undefined, rights: 2,
                                                        name: $0.element.name) }
        let module = PCCModule(id: nextId, guid: MacroBlock.guid, name: call.instanceName ?? name,
                               x: 32, y: 32, order: 10, threadId: page.stThreadID, page: caption,
                               inPins: inPins, paramPins: [], outPins: outPins,
                               rawAttributes: AttributeBag([("MACRO_NAME", name), ("MARAFLOW_ST", "1")]))
        nextId += 1
        project.modules.append(module)
        for (index, argument) in inputArgs.enumerated() {
            guard case .variable(let variableName) = argument.operand else { continue }
            if variables[variableName.lowercased()] == nil {
                notes.append("ST page '\(caption)': macro argument '\(variableName)' is not declared.")
                continue
            }
            if let source = variables[variableName.lowercased()] {
                project.connect(outModuleId: source, outPinId: 0, toModuleId: module.id, inPinId: index)
            }
        }
        for (index, argument) in outputArgs.enumerated() {
            guard case .variable(let variableName) = argument.operand else { continue }
            if variables[variableName.lowercased()] == nil {
                variableTypes[variableName.lowercased()] = "INT"
                let id = nextId
                nextId += 1
                let variableBlock = BlockFactory.makeModule(guid: BlockTypeCatalog.info(forBlockName: "IntVar")!.guid,
                                                            id: id, name: variableName, x: 32, y: 200, order: 1,
                                                            threadId: page.stThreadID, page: caption)
                project.modules.append(variableBlock)
                variables[variableName.lowercased()] = id
            }
            guard let variableId = variables[variableName.lowercased()] else { continue }
            let set = BlockFactory.makeModule(guid: SetBlock.guid, id: nextId, name: "Set_\(variableName)",
                                              x: 96, y: 200, order: 20, threadId: page.stThreadID, page: caption)
            nextId += 1
            project.modules.append(set)
            project.connect(outModuleId: module.id, outPinId: index, toModuleId: set.id, inPinId: 1)
            project.connect(outModuleId: variableId, outPinId: 0, toModuleId: set.id, inPinId: 2)
        }
    }

    /// Masks `VAR…END_VAR` blocks and splits the executable body into statements, carrying the `// Block: <defId>`
    /// comment that the Maraflow editor writes before each generated call.
    private static func stStatements(_ code: String) -> [(String, String?)] {
        var body = code
        if let block = try? NSRegularExpression(pattern: "(?is)\\b(?:VAR_INPUT|VAR_OUTPUT|VAR_TEMP|VAR)\\b.*?\\bEND_VAR\\b") {
            body = block.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body),
                                                   withTemplate: "\n")
        }
        var result: [(String, String?)] = []
        var currentDefinition: String?
        var buffer = ""
        for line in body.components(separatedBy: .newlines) {
            var line = line
            if let range = line.range(of: "// Block:") {
                currentDefinition = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<range.lowerBound])
            } else if let range = line.range(of: "//") {
                line = String(line[..<range.lowerBound])
            }
            buffer += line + "\n"
            while let semicolon = buffer.firstIndex(of: ";") {
                let statement = String(buffer[..<semicolon])
                buffer = String(buffer[buffer.index(after: semicolon)...])
                result.append((statement, currentDefinition))
                currentDefinition = nil
            }
        }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append((rest, currentDefinition)) }
        return result
    }

    private static func stDeclarations(in code: String, fallback: [MaraflowStVariable]) -> [STVariable] {
        var result: [STVariable] = fallback.map { STVariable(name: $0.name, type: $0.type, initial: $0.initial) }
        guard let block = try? NSRegularExpression(pattern: "(?is)\\b(?:VAR_INPUT|VAR_OUTPUT|VAR_TEMP|VAR)\\b(.*?)\\bEND_VAR\\b"),
              let line = try? NSRegularExpression(pattern: "(?im)^\\s*([A-Za-z_]\\w*)\\s*:\\s*([A-Za-z_]\\w*)(?:\\s*:=\\s*([^;]+))?\\s*;")
        else { return result }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in block.matches(in: code, range: range) {
            guard let contentRange = Range(match.range(at: 1), in: code) else { continue }
            let content = String(code[contentRange])
            let contentNS = NSRange(content.startIndex..<content.endIndex, in: content)
            for decl in line.matches(in: content, range: contentNS) {
                guard let nameRange = Range(decl.range(at: 1), in: content),
                      let typeRange = Range(decl.range(at: 2), in: content) else { continue }
                let name = String(content[nameRange])
                let type = String(content[typeRange])
                var initial = "0"
                if decl.range(at: 3).location != NSNotFound, let initialRange = Range(decl.range(at: 3), in: content) {
                    initial = String(content[initialRange]).trimmingCharacters(in: .whitespaces)
                }
                if let index = result.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    result[index] = STVariable(name: name, type: type, initial: initial)
                } else {
                    result.append(STVariable(name: name, type: type, initial: initial))
                }
            }
        }
        return result
    }

    private struct MaraflowSTCall {
        var typeName: String
        var instanceName: String?
        var assignmentTarget: String?
        var arguments: String
    }

    private static func stCall(_ statement: String) -> MaraflowSTCall? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)^\\s*(?:([A-Za-z_]\\w*)\\s*:=\\s*)?([A-Za-z_]\\w*)\\s*\\((.*)\\)\\s*$"),
              let match = regex.firstMatch(in: statement, range: NSRange(statement.startIndex..<statement.endIndex, in: statement))
        else { return nil }
        func group(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: statement)
            else { return nil }
            return String(statement[range])
        }
        guard let typeName = group(2), let arguments = group(3) else { return nil }
        return MaraflowSTCall(typeName: typeName, instanceName: group(1) == nil ? nil : nil,
                              assignmentTarget: group(1), arguments: arguments)
    }

    private static func stArguments(_ text: String) -> [STCallArgument] {
        stSplit(text, on: ",").compactMap { part in
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { return nil }
            if let regex = try? NSRegularExpression(pattern: "(?is)^\\s*([A-Za-z_]\\w*)\\s*=>\\s*([A-Za-z_]\\w*)\\s*$"),
               let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..<part.endIndex, in: part)),
               let variable = Range(match.range(at: 2), in: part).map({ String(part[$0]) }) {
                return STCallArgument(name: "=>", operand: .variable(variable))
            }
            if let regex = try? NSRegularExpression(pattern: "(?is)^\\s*([A-Za-z_]\\w*)\\s*:=\\s*(.+?)\\s*$"),
               let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..<part.endIndex, in: part)),
               let name = Range(match.range(at: 1), in: part).map({ String(part[$0]) }),
               let value = Range(match.range(at: 2), in: part).map({ String(part[$0]) }),
               let operand = stOperand(value) {
                return STCallArgument(name: name, operand: operand)
            }
            guard let operand = stOperand(part) else { return nil }
            return STCallArgument(name: nil, operand: operand)
        }
    }

    private static func stOperand(_ text: String) -> STOperand? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.caseInsensitiveCompare("true") == .orderedSame { return .literal(.bool(true)) }
        if text.caseInsensitiveCompare("false") == .orderedSame { return .literal(.bool(false)) }
        if text.range(of: "^[A-Za-z_]\\w*$", options: .regularExpression) != nil { return .variable(text) }
        if text.range(of: "^[-+]?\\d+$", options: .regularExpression) != nil {
            return .literal(.int32(Int32(clamping: parseInteger(text))))
        }
        if text.range(of: "^[-+]?(?:\\d+\\.\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?$", options: .regularExpression) != nil,
           let value = Float(text) {
            return .literal(.float(value))
        }
        return nil
    }

    private static func stStaticValue(_ operand: STOperand) -> PinValue {
        if case .literal(let value) = operand { return value }
        return .undefined
    }

    private static func stSplit(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == separator && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func stDefinitionId(for typeName: String) -> String? {
        let key = typeName.lowercased()
        if let exact = mappings.first(where: { $0.key.split(separator: ".").last?.lowercased() == key })?.key {
            return exact
        }
        return nil
    }

    private static func stType(_ type: String) -> String {
        switch type.uppercased() {
        case "BOOL", "BOOLEAN": return "BOOL"
        case "LONG", "LINT": return "LONG"
        case "FLOAT", "REAL": return "FLOAT"
        default: return "INT"
        }
    }

    private static func stPinValue(_ text: String, type: String) -> PinValue {
        switch type {
        case "BOOL": return .bool(text == "1" || text.lowercased() == "true")
        case "LONG": return .int64(parseInteger(text))
        case "FLOAT": return .float(Float(text) ?? 0)
        default: return .int32(Int32(clamping: parseInteger(text)))
        }
    }

    private static func stAssignment(_ text: String) -> (target: String, value: STOperand)? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)^\\s*([A-Za-z_]\\w*)\\s*:=\\s*(.+?)\\s*$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let target = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
              let value = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
              let operand = stOperand(value) else { return nil }
        return (target, operand)
    }

    private static func applySTAssignment(_ assignment: (target: String, value: STOperand),
                                          variables: inout [String: Int], variableTypes: inout [String: String],
                                          project: inout PCCProject, nextId: inout Int, caption: String,
                                          page: MaraflowPage, notes: inout [String]) {
        let key = assignment.target.lowercased()
        guard let variableId = variables[key] else {
            notes.append("ST page '\(caption)': assignment to undeclared '\(assignment.target)' was skipped.")
            return
        }
        let set = BlockFactory.makeModule(guid: SetBlock.guid, id: nextId, name: "Set_\(assignment.target)",
                                          x: 32, y: 32, order: 10, threadId: page.stThreadID, page: caption)
        nextId += 1
        project.modules.append(set)
        switch assignment.value {
        case .literal(let value):
            setInPin(project: &project, moduleId: set.id, pin: 1, value: value)
        case .variable(let source):
            if let sourceId = variables[source.lowercased()] {
                project.connect(outModuleId: sourceId, outPinId: 0, toModuleId: set.id, inPinId: 1)
            } else {
                notes.append("ST page '\(caption)': assignment reads undeclared '\(source)'.")
            }
        }
        project.connect(outModuleId: variableId, outPinId: 0, toModuleId: set.id, inPinId: 2)
    }

    private static func setInPin(project: inout PCCProject, moduleId: Int, pin: Int, value: PinValue) {
        guard let index = project.modules.firstIndex(where: { $0.id == moduleId }),
              project.modules[index].inPins.indices.contains(pin) else { return }
        project.modules[index].inPins[pin].value = value
    }

    private enum MacroInterfaceKind {
        case inputs
        case outputs
    }

    private static func macroInterface(_ block: MaraflowBlock, kind: MacroInterfaceKind, id: Int,
                                       page: String) -> PCCModule {
        let pins = kind == .inputs
            ? block.outputs.enumerated().map { Pin(id: $0.offset, value: value(for: $0.element), rights: 2,
                                                   name: $0.element.short) }
            : []
        let inPins = kind == .outputs
            ? block.inputs.enumerated().map { Pin(id: $0.offset, value: value(for: $0.element), rights: 0,
                                                  name: $0.element.short) }
            : []
        return PCCModule(id: id, guid: InputsBlock.guid, name: block.name, x: Double(block.gridX * 32),
                         y: Double(block.gridY * 32), order: block.order, threadId: block.threadId,
                         page: page, inPins: inPins, paramPins: [], outPins: pins,
                         rawAttributes: AttributeBag([("MACRO_NAME", kind == .inputs ? "Inputs" : "Outputs"),
                                                      ("KIND", kind == .inputs ? "0" : "1")]),
                         rawChildren: [])
    }

    private static func macroCall(_ block: MaraflowBlock, id: Int, page: String) -> PCCModule {
        let name = String(block.definitionId.dropFirst("Macro.User.".count))
        let inPins = block.inputs.enumerated().map {
            Pin(id: $0.offset, value: value(for: $0.element), rights: 0, name: $0.element.short)
        }
        let outPins = block.outputs.enumerated().map {
            Pin(id: $0.offset, value: value(for: $0.element), rights: 2, name: $0.element.short)
        }
        return PCCModule(id: id, guid: MacroBlock.guid, name: block.name, x: Double(block.gridX * 32),
                         y: Double(block.gridY * 32), order: block.order, threadId: block.threadId,
                         page: page, inPins: inPins, paramPins: [], outPins: outPins,
                         rawAttributes: AttributeBag([("MACRO_NAME", name.isEmpty ? block.typeName : name),
                                                      ("MARAFLOW_DEF", block.definitionId),
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
