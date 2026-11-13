#if WIREBENCH_AI
import Foundation
import WirebenchCore
import WirebenchLibrary

/// One function the agent may call, as the chat-completions API describes it.
public struct AgentTool: Sendable {
    public var name: String
    public var summary: String
    /// The JSON Schema of its arguments, as JSON text (a string keeps the struct `Sendable`).
    public var schema: String
    /// Whether it changes anything: the project, a file, or the running simulation.
    public var changes: Bool

    /// The description the API takes: `{type: "function", function: {name, description, parameters}}`.
    var apiObject: [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) ?? ["type": "object", "properties": [String: Any]()]
        return ["type": "function", "function": ["name": name, "description": summary, "parameters": parameters]]
    }
}

/// What a tool call came to: the text the model reads, and a line the user reads.
public struct AgentToolOutcome: Sendable {
    public var result: String
    public var summary: String
    public var failed: Bool
}

/// The agent's hands: the functions it can call, run against the open project through the same `AppModel` both frontends use, so a
/// change made here is an ordinary edit (undoable with Undo) in either app.
///
/// The tools that change something are offered only when the user has allowed editing, and refuse if called anyway. What is left out on
/// purpose: anything that reaches the hardware (connecting to a PLC, uploading), changing settings, and overwriting a file other than the
/// one that is open.
public final class AgentToolbox: @unchecked Sendable {
    private unowned let model: AppModel
    /// The most text a single result may carry back to the model.
    private static let limit = 24_000

    public init(model: AppModel) { self.model = model }

    // MARK: - The catalogue

    private static func schema(_ properties: [(String, String, String)] = [], required: [String] = [], extra: [String: Any] = [:]) -> String {
        var props: [String: Any] = [:]
        for (name, type, text) in properties { props[name] = ["type": type, "description": text] }
        for (name, value) in extra { props[name] = value }
        var object: [String: Any] = ["type": "object", "properties": props]
        // OpenAI rejects an empty `required` ("[] is too short"), so it is left out when there is nothing in it.
        if !required.isEmpty { object["required"] = required }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    private static let blockID = ("block", "integer", "The block's id, as in the project (shown as #id; from read_page).")

    public static let reading: [AgentTool] = [
        AgentTool(name: "project_overview",
                  summary: "The open project: its name and file, its pages (macro pages start with *) with how many blocks each holds, the page being shown, whether there are unsaved changes, and the simulation's state. Call this first.",
                  schema: schema(), changes: false),
        AgentTool(name: "read_page",
                  summary: "Every block on a page and every wire. A block lists its id, name, type, position, execution order and thread, and its pins in order with live values: \"in\" are inputs (index 0 is usually En), \"out\" outputs, \"param\" parameters. A wire \"3:0>4:1\" runs from block 3's output pin 0 to block 4's input pin 1. Pin indices are positions in those lists, from 0.",
                  schema: schema([("page", "string", "The page's caption. Defaults to the page being shown.")]), changes: false),
        AgentTool(name: "read_block",
                  summary: "One block in full: its pins with live values and what each means, its position, order, thread, and the configuration fields configure_block can set (key, kind, current value, allowed range or options).",
                  schema: schema([blockID], required: ["block"]), changes: false),
        AgentTool(name: "find_block_types",
                  summary: "Searches the block library by name, category or description. Returns type names to give add_block. With no query, lists the categories and a few of the common blocks. Macro pages that can be called from this page are listed too.",
                  schema: schema([("query", "string", "Words to look for, e.g. \"counter\", \"timer\", \"and\", \"7 segment\".")]), changes: false),
        AgentTool(name: "block_help",
                  summary: "The reference for one block type: what it does, its pins in order with data types and defaults, and its rules. Read it before using a block you are not sure of.",
                  schema: schema([("type", "string", "A block type name, e.g. \"Counter\".")], required: ["type"]), changes: false),
        AgentTool(name: "build_report",
                  summary: "Compiles the project to a PLC program (nothing is sent anywhere) and says how it went: sizes, how many blocks compiled, and anything the compiler could not handle. Use it to check that a project is sound.",
                  schema: schema(), changes: false),
    ]

    public static let editing: [AgentTool] = [
        AgentTool(name: "add_block",
                  summary: "Adds a block to the page being shown. Returns its id and its pins, so you can wire it at once. Blocks are about 110 wide, so leave 160 or more between columns; wires run left to right, from outputs on a block's right to inputs on the left of the next one.",
                  schema: schema([("type", "string", "A block type name from find_block_types, e.g. \"And\", \"Counter\", \"BoolVar\"."),
                                  ("x", "number", "Left edge on the sheet. Optional."), ("y", "number", "Top edge. Optional."),
                                  ("name", "string", "A name for this block, e.g. \"StartButton\". Optional.")], required: ["type"]), changes: true),
        AgentTool(name: "add_macro_call",
                  summary: "Adds a call to a macro page, a reusable sub-sheet. The call has the macro's Inputs as its inputs and its Outputs as its outputs.",
                  schema: schema([("macro", "string", "The macro page's caption, e.g. \"*negr\"."), ("x", "number", "Left edge. Optional."),
                                  ("y", "number", "Top edge. Optional.")], required: ["macro"]), changes: true),
        AgentTool(name: "add_macro_interface",
                  summary: "On a macro page, adds its Inputs block (what a call receives) or its Outputs block (what it returns). A macro page has at most one of each. Then add_interface_pin gives it pins.",
                  schema: schema([("kind", "string", "\"inputs\" or \"outputs\".")], required: ["kind"]), changes: true),
        AgentTool(name: "add_interface_pin",
                  summary: "Adds a pin to a macro's Inputs or Outputs block, or renames or removes one.",
                  schema: schema([blockID, ("op", "string", "\"add\", \"rename\" or \"remove\"."), ("pin", "integer", "Which pin, for rename and remove."),
                                  ("name", "string", "The new name, for rename.")], required: ["block", "op"]), changes: true),
        AgentTool(name: "delete_blocks",
                  summary: "Deletes blocks and the wires on them.",
                  schema: schema(extra: ["blocks": ["type": "array", "items": ["type": "integer"], "description": "The ids to delete."]]), changes: true),
        AgentTool(name: "move_block",
                  summary: "Moves a block to a position on the sheet (its top-left corner).",
                  schema: schema([blockID, ("x", "number", "Left edge."), ("y", "number", "Top edge.")], required: ["block", "x", "y"]), changes: true),
        AgentTool(name: "rename_block",
                  summary: "Gives a block a name.",
                  schema: schema([blockID, ("name", "string", "The new name.")], required: ["block", "name"]), changes: true),
        AgentTool(name: "connect",
                  summary: "Wires an output pin to an input pin. An input takes one wire, so a new one replaces what was there; one output may feed many inputs. Both blocks must be on the same page. Check execution order: a wire should run from a lower order to a higher one, unless it is meant as a feedback loop.",
                  schema: schema([("from_block", "integer", "The block the wire starts at."), ("from_pin", "integer", "Its output pin index, from 0."),
                                  ("to_block", "integer", "The block the wire ends at."), ("to_pin", "integer", "Its input pin index, from 0."),
                                  ("to_param", "boolean", "True when to_pin counts the block's parameter pins (PV, Max, Min…) instead of its inputs. Optional.")],
                                 required: ["from_block", "from_pin", "to_block", "to_pin"]), changes: true),
        AgentTool(name: "disconnect",
                  summary: "Removes the wire going into an input pin.",
                  schema: schema([("to_block", "integer", "The block with the input."), ("to_pin", "integer", "The input pin index.")],
                                 required: ["to_block", "to_pin"]), changes: true),
        AgentTool(name: "set_input_value",
                  summary: "Sets an input pin that has no wire to a value: 0 or 1 for a switch pin, a number for a numeric pin. A wired pin takes its value from the wire instead.",
                  schema: schema([blockID, ("pin", "integer", "The input pin index."), ("value", "number", "The value.")], required: ["block", "pin", "value"]), changes: true),
        AgentTool(name: "set_variable",
                  summary: "Sets a variable block's value: a BoolVar to 0 or 1 (a latched switch, or the level of a button), an IntVar or LongVar to a whole number.",
                  schema: schema([blockID, ("value", "number", "The value.")], required: ["block", "value"]), changes: true),
        AgentTool(name: "set_param",
                  summary: "Sets a parameter pin (such as a counter's step) to a whole number. Parameters are the \"param\" list in read_block.",
                  schema: schema([blockID, ("pin", "integer", "The parameter's index, from 0."), ("value", "integer", "The value.")], required: ["block", "pin", "value"]), changes: true),
        AgentTool(name: "configure_block",
                  summary: "Changes a block's configuration: the number of inputs of an And, a timer's mode, a pulse generator's times, and so on. Use read_block first for the field keys, their kinds and what they accept.",
                  schema: schema([blockID], required: ["block", "values"],
                                 extra: ["values": ["type": "object", "description": "Field key to new value, every value a string, e.g. {\"inputs\": \"4\"}.",
                                                    "additionalProperties": ["type": "string"]]]), changes: true),
        AgentTool(name: "set_order_and_thread",
                  summary: "Sets a block's execution order within its thread, and/or the thread it runs in. Blocks run in order, low to high; wires should go from lower to higher orders.",
                  schema: schema([blockID, ("order", "integer", "The execution order (Dirigo numbers in tens)."), ("thread", "integer", "The thread index.")], required: ["block"]), changes: true),
        AgentTool(name: "add_page",
                  summary: "Adds a page and shows it. A macro page's caption starts with *.",
                  schema: schema([("caption", "string", "The page's name."), ("macro", "boolean", "True to make it a macro page (reusable).")], required: ["caption"]), changes: true),
        AgentTool(name: "delete_page",
                  summary: "Deletes a page and its blocks.",
                  schema: schema([("caption", "string", "The page's caption.")], required: ["caption"]), changes: true),
        AgentTool(name: "go_to_page",
                  summary: "Shows a page, which is where add_block and the other editing tools work.",
                  schema: schema([("caption", "string", "The page's caption.")], required: ["caption"]), changes: true),
        AgentTool(name: "organize_blocks",
                  summary: "Lays out the page being shown so signals flow left to right. Do this after adding several blocks, instead of placing each by hand.",
                  schema: schema(), changes: true),
        AgentTool(name: "reset_wire_routing",
                  summary: "Re-routes every wire on the page from scratch.",
                  schema: schema(), changes: true),
        AgentTool(name: "add_text",
                  summary: "Puts a text label on the sheet.",
                  schema: schema([("text", "string", "The text."), ("x", "number", "Left edge. Optional."), ("y", "number", "Top edge. Optional.")], required: ["text"]), changes: true),
        AgentTool(name: "add_shape",
                  summary: "Draws a rectangle or ellipse on the sheet, e.g. to group blocks visually.",
                  schema: schema([("kind", "string", "\"rectangle\" or \"ellipse\"."), ("x", "number", "Optional."), ("y", "number", "Optional.")], required: ["kind"]), changes: true),
        AgentTool(name: "simulation",
                  summary: "Controls the simulation: play, pause, step (one cycle, while paused), reset, or set the speed. Read values with read_page afterwards.",
                  schema: schema([("action", "string", "\"play\", \"pause\", \"step\", \"reset\" or \"speed\"."),
                                  ("speed_percent", "integer", "For \"speed\": 10, 25, 50, 100, 200, 400 or 1000 (1000 is real time).")], required: ["action"]), changes: true),
        AgentTool(name: "undo", summary: "Undoes the last edit (edits made together, within a fraction of a second, undo as one).", schema: schema(), changes: true),
        AgentTool(name: "redo", summary: "Redoes what was undone.", schema: schema(), changes: true),
        AgentTool(name: "new_project",
                  summary: "Starts an empty project. Refused while the open one has unsaved changes: save it first.",
                  schema: schema(), changes: true),
        AgentTool(name: "open_project",
                  summary: "Opens a .wbp project file (a legacy .pcc is imported). Refused while the open project has unsaved changes.",
                  schema: schema([("path", "string", "The file's full path.")], required: ["path"]), changes: true),
        AgentTool(name: "save_project",
                  summary: "Saves the project: to the file it was opened from, or, if it has none yet (or you give a path), to a new .wbp file. It never overwrites a different file that already exists.",
                  schema: schema([("path", "string", "A full path ending in .wbp. Optional once the project has a file.")]), changes: true),
    ]

    /// The tools offered to the model: the ones that read always, the ones that change things only when editing is allowed.
    public static func offered(canEdit: Bool) -> [AgentTool] { canEdit ? reading + editing : reading }

    /// What to show while a tool runs: "Reading the page…".
    public static func activity(for tool: String) -> String {
        switch tool {
        case "project_overview", "read_page", "read_block": return "Reading the project…"
        case "find_block_types", "block_help": return "Looking up blocks…"
        case "build_report": return "Building…"
        case "simulation": return "Running the simulation…"
        case "save_project", "open_project", "new_project": return "Working with files…"
        default: return "Editing the project…"
        }
    }

    // MARK: - Running one

    /// Runs a tool the model asked for. `arguments` is the JSON text it gave.
    @MainActor
    public func run(name: String, arguments: String, canEdit: Bool) -> AgentToolOutcome {
        guard let tool = (Self.reading + Self.editing).first(where: { $0.name == name }) else {
            return failure("There is no tool called \(name).", summary: "Unknown tool \(name)")
        }
        if tool.changes && !canEdit {
            return failure("Editing is turned off, so this was not done. Tell the user they can allow editing in the agent panel.",
                           summary: "Blocked \(name): editing is off")
        }
        let parsed: Any? = arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [String: Any]() : try? JSONSerialization.jsonObject(with: Data(arguments.utf8))
        guard let args = parsed as? [String: Any] else {
            return failure("The arguments were not a JSON object: \(arguments)", summary: "Bad arguments for \(name)")
        }
        guard model.project != nil || ["project_overview", "find_block_types", "block_help", "new_project", "open_project"].contains(name) else {
            return failure("No project is open. Use new_project or open_project, or ask the user to.", summary: "No project open")
        }
        return perform(name, args)
    }

    // MARK: - Helpers

    private func failure(_ message: String, summary: String) -> AgentToolOutcome {
        AgentToolOutcome(result: "Error: " + message, summary: summary, failed: true)
    }

    private func done(_ result: Any, summary: String) -> AgentToolOutcome {
        var text: String
        if let string = result as? String { text = string }
        else { text = String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data(), as: UTF8.self) }
        if text.count > Self.limit {
            text = String(text.prefix(Self.limit)) + "\n…cut off: the page is large. Ask for a smaller one, or read single blocks with read_block."
        }
        return AgentToolOutcome(result: text, summary: summary, failed: false)
    }

    private func int(_ args: [String: Any], _ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }
    private func double(_ args: [String: Any], _ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
    private func string(_ args: [String: Any], _ key: String) -> String? { args[key] as? String }

    @MainActor private func module(_ id: Int?) -> PCCModule? { id.flatMap { model.module(id: $0) } }

    @MainActor private func value(_ pin: PinValue?) -> String { pin.map { $0.description } ?? "?" }

    /// A block's pins by position, with live values: `["En=1", "X0=0"]`.
    @MainActor private func pinLists(_ module: PCCModule) -> (inputs: [String], outputs: [String], params: [String]) {
        let live = model.snapshots[module.id]
        let inputs = module.inPins.indices.map { i in
            "\(ModulePinCatalog.inputPinLabel(for: module, index: i))=\(value(live?.inValues[safe: i] ?? module.inPins[i].value))"
        }
        let outputs = module.outPins.indices.map { i in
            "\(ModulePinCatalog.outputPinLabel(for: module, index: i))=\(value(live?.outValues[safe: i] ?? module.outPins[i].value))"
        }
        let params = module.paramPins.indices.map { i in
            "\(ModulePinCatalog.paramPinLabel(for: module, index: i))=\(value(live?.paramValues[safe: i] ?? module.paramPins[i].value))"
        }
        return (inputs, outputs, params)
    }

    @MainActor private func describe(_ module: PCCModule) -> [String: Any] {
        let pins = pinLists(module)
        var block: [String: Any] = [
            "id": module.id, "name": module.name,
            "type": BlockTypeCatalog.info(forGuid: module.guid)?.blockName ?? MacroCalls.target(of: module).map { "macro call *\($0)" } ?? "?",
            "x": Int(module.x), "y": Int(module.y), "order": module.order, "thread": module.threadId,
            "in": pins.inputs, "out": pins.outputs,
        ]
        if !pins.params.isEmpty { block["param"] = pins.params }
        return block
    }

    // MARK: - The tools

    @MainActor
    private func perform(_ name: String, _ args: [String: Any]) -> AgentToolOutcome {
        switch name {
        case "project_overview":
            var overview: [String: Any] = [
                "open": model.project != nil, "edited": model.isDocumentEdited,
                "can_undo": model.canUndo, "can_redo": model.canRedo,
                "simulation": ["playing": model.isPlaying, "tick": Int(model.tickCount), "speed_percent": Int((model.simulationSpeed * 100).rounded())],
            ]
            if let project = model.project {
                overview["name"] = project.name
                overview["file"] = model.currentFileURL?.path ?? "(not saved yet)"
                overview["current_page"] = model.selectedPage
                overview["pages"] = project.pages.map { page in
                    ["caption": page.caption, "macro": page.caption.hasPrefix("*"),
                     "blocks": project.modules.filter { $0.page == page.caption }.count] as [String: Any]
                }
                overview["profile"] = project.profile
            }
            return done(overview, summary: "Looked at the project")

        case "read_page":
            guard let project = model.project else { return failure("No project.", summary: "No project open") }
            let page = string(args, "page") ?? model.selectedPage
            guard project.pages.contains(where: { $0.caption == page }) else {
                return failure("There is no page \"\(page)\". Pages: \(project.pages.map(\.caption).joined(separator: ", ")).", summary: "No page \(page)")
            }
            let blocks = project.modules.filter { $0.page == page }
            let ids = Set(blocks.map(\.id))
            let wires = project.inConnections.filter { ids.contains($0.outModuleId) && ids.contains($0.inModuleId) }
                .map { "\($0.outModuleId):\($0.outPinId)>\($0.inModuleId):\($0.inPinId)" }
            return done(["page": page, "blocks": blocks.map(describe), "wires": wires] as [String: Any], summary: "Read page \(page) (\(blocks.count) blocks)")

        case "read_block":
            guard let module = module(int(args, "block")), let snapshot = InspectorSnapshot.make(of: model, moduleId: module.id) else {
                return failure("There is no block with that id. Use read_page for the ids.", summary: "No such block")
            }
            var block = describe(module)
            block["page"] = module.page
            block["summary"] = snapshot.summary
            block["inputs"] = snapshot.inputs.enumerated().map { ["pin": $0.offset, "label": $0.element.label, "value": $0.element.value] }
            block["outputs"] = snapshot.outputs.enumerated().map { ["pin": $0.offset, "label": $0.element.label, "value": $0.element.value] }
            block["params"] = snapshot.params.enumerated().map { ["pin": $0.offset, "label": $0.element.label, "value": $0.element.value] }
            if let config = BlockConfig.make(of: model, moduleId: module.id) {
                block["configuration"] = config.fields.map { field -> [String: Any] in
                    var entry: [String: Any] = ["key": field.key, "label": field.label, "kind": field.kind, "value": field.value]
                    if let min = field.min { entry["min"] = min }
                    if let max = field.max { entry["max"] = max }
                    if let options = field.options { entry["options"] = options.map { ["value": $0.value, "label": $0.label] } }
                    if let hint = field.hint { entry["hint"] = hint }
                    return entry
                }
            }
            return done(block, summary: "Read \(module.name)")

        case "find_block_types":
            let query = (string(args, "query") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let words = query.split(separator: " ").map(String.init)
            let scored: [(BlockTypeInfo, Int)] = BlockTypeCatalog.all.compactMap { info in
                guard BlockPaletteSearch.isOffered(info) else { return nil }
                if words.isEmpty { return (info, 0) }
                let name = info.blockName.lowercased(), text = (info.summary + " " + info.category).lowercased()
                var score = 0
                for word in words {
                    if name == word { score += 10 } else if name.hasPrefix(word) { score += 6 } else if name.contains(word) { score += 4 }
                    else if text.contains(word) { score += 1 } else { return nil }
                }
                return (info, score)
            }
            let hits = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.blockName < $1.0.blockName }.prefix(30)
            var result: [String: Any] = [
                "blocks": hits.map { ["type": $0.0.blockName, "category": BlockPaletteSearch.displayName(for: $0.0.category), "summary": $0.0.summary] },
            ]
            if !model.callableMacros.isEmpty { result["macros_callable_from_this_page"] = model.callableMacros }
            if hits.isEmpty { result["note"] = "No block matches. Try a shorter or different word." }
            return done(result, summary: query.isEmpty ? "Listed block types" : "Searched block types for \"\(query)\"")

        case "block_help":
            guard let type = string(args, "type") else { return failure("Give a type.", summary: "No type given") }
            let key = type.lowercased()
            if let entry = AgentBlockDocs.entries[key] ?? AgentBlockDocs.entries.first(where: { $0.key.hasPrefix(key) })?.value {
                return done(entry, summary: "Read the reference for \(type)")
            }
            return failure("No reference for \"\(type)\". Use find_block_types to find the exact name.", summary: "No reference for \(type)")

        case "build_report":
            guard let report = model.compileProject() else { return failure("The project could not be compiled.", summary: "Build failed") }
            let result: [String: Any] = [
                "summary": report.summary, "blocks": report.moduleCount, "compiled": report.compiledModules,
                "display_only": report.displayModules, "record_bytes": report.recordBytes, "data_slots": report.dataSlots,
                "terminals": report.terminals, "symbol_rows": report.symbolRows, "not_compiled": report.unshaped, "macros": report.macros,
            ]
            return done(result, summary: "Built the project: \(report.summary)")

        default:
            return performEdit(name, args)
        }
    }

    /// Resolves what the model called a block type: a type name in any case, a GUID, or a unique prefix.
    @MainActor private func resolveType(_ text: String) -> BlockTypeInfo? {
        if let guid = UUID(uuidString: text.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))), let info = BlockTypeCatalog.info(forGuid: guid) { return info }
        if let info = BlockTypeCatalog.info(forBlockName: text) { return info }
        let matches = BlockTypeCatalog.all.filter { $0.blockName.lowercased().hasPrefix(text.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor
    private func performEdit(_ name: String, _ args: [String: Any]) -> AgentToolOutcome {
        func point() -> CGPoint? {
            guard let x = double(args, "x"), let y = double(args, "y") else { return nil }
            return CGPoint(x: x, y: y)
        }
        switch name {
        case "add_block":
            guard let text = string(args, "type") else { return failure("Give a type.", summary: "No type given") }
            guard let info = resolveType(text) else {
                return failure("No block type \"\(text)\". Use find_block_types to find the exact name.", summary: "No block type \(text)")
            }
            if info.guid == SystemCmdBlock.guid {
                return failure("SystemCmd is not a block on a page here: the PLC's commands are in the project's PLC Configuration, which the user edits (Build > PLC Configuration) and which Export Legacy .PCC writes out as SystemCmd blocks.", summary: "SystemCmd is configured separately")
            }
            guard let id = model.addBlock(guid: info.guid, at: point()), let module = module(id) else {
                return failure("The block could not be added.", summary: "Could not add \(info.blockName)")
            }
            if let name = string(args, "name"), !name.isEmpty { model.renameModule(id: id, name: name) }
            let added = self.module(id) ?? module
            let label = added.name == info.blockName ? info.blockName : "\(info.blockName) \(added.name)"
            return done(describe(added), summary: "Added \(label) (#\(id))")

        case "add_macro_call":
            guard let sheet = string(args, "macro") else { return failure("Give a macro.", summary: "No macro given") }
            guard let id = model.addMacroCall(sheet: sheet, at: point()), let module = module(id) else {
                return failure("Cannot call \"\(sheet)\" from this page. Callable: \(model.callableMacros.joined(separator: ", ")).", summary: "Could not add a call to \(sheet)")
            }
            return done(describe(module), summary: "Added a call to \(sheet) (#\(id))")

        case "add_macro_interface":
            guard let kind = ["inputs": MacroInterface.Kind.inputs, "outputs": .outputs][(string(args, "kind") ?? "").lowercased()] else {
                return failure("kind is \"inputs\" or \"outputs\".", summary: "Bad kind")
            }
            guard let id = model.addMacroInterface(kind), let module = module(id) else {
                return failure("This page already has one, or is not a macro page.", summary: "Could not add the \(kind.attributeName) block")
            }
            return done(describe(module), summary: "Added the \(kind.attributeName) block (#\(id))")

        case "add_interface_pin":
            guard let id = int(args, "block"), module(id) != nil else { return failure("No such block.", summary: "No such block") }
            switch string(args, "op") ?? "" {
            case "add": model.addInterfacePin(moduleId: id)
            case "rename":
                guard let pin = int(args, "pin"), let name = string(args, "name") else { return failure("rename needs pin and name.", summary: "Bad arguments") }
                model.renameInterfacePin(moduleId: id, pin: pin, to: name)
            case "remove":
                guard let pin = int(args, "pin") else { return failure("remove needs pin.", summary: "Bad arguments") }
                model.removeInterfacePin(moduleId: id, pin: pin)
            default: return failure("op is add, rename or remove.", summary: "Bad op")
            }
            return done(module(id).map(describe) ?? [:], summary: "Changed the pins of #\(id)")

        case "delete_blocks":
            let ids = (args["blocks"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            guard !ids.isEmpty else { return failure("Give the ids in blocks.", summary: "No blocks given") }
            let missing = ids.filter { module($0) == nil }
            guard missing.isEmpty else { return failure("No such blocks: \(missing). Nothing was deleted.", summary: "No such blocks") }
            for id in ids { _ = model.deleteModule(id: id) }
            return done("Deleted \(ids.count) block(s) and their wires.", summary: "Deleted \(ids.count) block(s)")

        case "move_block":
            guard let module = module(int(args, "block")), let x = double(args, "x"), let y = double(args, "y") else {
                return failure("Needs block, x and y.", summary: "Bad arguments")
            }
            model.updateModulePosition(id: module.id, deltaX: x - module.x, deltaY: y - module.y, snapped: false)
            return done("Moved \(module.name) to (\(Int(x)), \(Int(y))).", summary: "Moved \(module.name)")

        case "rename_block":
            guard let module = module(int(args, "block")), let name = string(args, "name"), !name.isEmpty else {
                return failure("Needs block and name.", summary: "Bad arguments")
            }
            model.renameModule(id: module.id, name: name)
            return done("Renamed to \(self.module(module.id)?.name ?? name).", summary: "Renamed \(module.name) to \(name)")

        case "connect":
            guard let from = module(int(args, "from_block")), let to = module(int(args, "to_block")),
                  let outPin = int(args, "from_pin"), let inPin = int(args, "to_pin") else {
                return failure("Needs from_block, from_pin, to_block and to_pin, and both blocks must exist.", summary: "Bad arguments")
            }
            guard from.id != to.id else {
                return failure("A block cannot be wired to itself. To close a loop (a counter that starts over), take the signal through another block, such as a Comparator whose output goes to the counter's Rst.", summary: "Same block")
            }
            let toParam = (args["to_param"] as? Bool) ?? false
            guard from.page == to.page else { return failure("The blocks are on different pages (\(from.page), \(to.page)); wires stay on one page.", summary: "Different pages") }
            guard outPin >= 0, outPin < from.outPins.count else {
                return failure("\(from.name) has \(from.outPins.count) output(s), numbered from 0: \(pinLists(from).outputs).", summary: "Could not wire \(from.name) → \(to.name): no output pin \(outPin)")
            }
            let targets = toParam ? to.paramPins.count : to.inPins.count
            guard inPin >= 0, inPin < targets else {
                let list = toParam ? "" : ": \(pinLists(to).inputs)"
                return failure("\(to.name) has \(targets) \(toParam ? "parameter" : "input")(s), numbered from 0\(list).", summary: "Could not wire \(from.name) → \(to.name): no \(toParam ? "parameter" : "input") pin \(inPin)")
            }
            guard model.connectPins(from: PinReference(moduleId: from.id, side: .output, index: outPin),
                                    to: PinReference(moduleId: to.id, side: toParam ? .param : .input, index: inPin)) else {
                return failure("That wire is already there, or could not be made.", summary: "Not connected")
            }
            let target = toParam ? ModulePinCatalog.paramPinLabel(for: to, index: inPin) : ModulePinCatalog.inputPinLabel(for: to, index: inPin)
            return done("Wired \(from.name) \(ModulePinCatalog.outputPinLabel(for: from, index: outPin)) to \(to.name) \(target).",
                        summary: "Wired \(from.name) → \(to.name)")

        case "disconnect":
            guard let to = module(int(args, "to_block")), let pin = int(args, "to_pin") else { return failure("Needs to_block and to_pin.", summary: "Bad arguments") }
            guard model.disconnectPin(PinReference(moduleId: to.id, side: .input, index: pin)) else {
                return failure("Nothing is wired to that input.", summary: "Nothing to disconnect")
            }
            return done("Removed the wire into \(to.name) input \(pin).", summary: "Removed a wire into \(to.name)")

        case "set_input_value":
            guard let module = module(int(args, "block")), let pin = int(args, "pin"), let number = double(args, "value"),
                  pin >= 0, pin < module.inPins.count else { return failure("Needs block, a valid input pin and value.", summary: "Bad arguments") }
            if case .bool = model.getNode(id: module.id)?.block.inPins[safe: pin] {
                model.setModuleInput(moduleId: module.id, pinIndex: pin, value: .bool(number != 0))
            } else {
                model.setModuleInput(moduleId: module.id, pinIndex: pin, value: .int32(Int32(truncatingIfNeeded: Int(number))))
            }
            return done("Set \(module.name) input \(pin) to \(number).", summary: "Set \(module.name) input \(pin) = \(number)")

        case "set_variable":
            guard let module = module(int(args, "block")), let number = double(args, "value") else { return failure("Needs block and value.", summary: "Bad arguments") }
            if BlockRole.boolVarMode(of: module) != nil {
                model.setModuleOutput(moduleId: module.id, pinIndex: 0, value: .bool(number != 0))
            } else if BlockRole.isIntVariable(module) {
                model.setVariableValue(moduleId: module.id, value: Int(number))
            } else {
                return failure("\(module.name) is not a BoolVar, IntVar or LongVar. Use set_input_value or configure_block.", summary: "Not a variable")
            }
            return done("Set \(module.name) to \(number).", summary: "Set \(module.name) = \(number)")

        case "set_param":
            guard let module = module(int(args, "block")), let pin = int(args, "pin"), let number = int(args, "value"),
                  pin >= 0, pin < module.paramPins.count else { return failure("Needs block, a valid parameter index and value.", summary: "Bad arguments") }
            model.updateModuleParam(id: module.id, paramIndex: pin, value: .int32(Int32(truncatingIfNeeded: number)))
            return done("Set parameter \(pin) of \(module.name) to \(number).", summary: "Set \(module.name) parameter \(pin) = \(number)")

        case "configure_block":
            guard let module = module(int(args, "block")), let values = args["values"] as? [String: Any], !values.isEmpty else {
                return failure("Needs block and values (field key to value).", summary: "Bad arguments")
            }
            guard let config = BlockConfig.make(of: model, moduleId: module.id) else {
                return failure("\(module.name) has nothing to configure.", summary: "Nothing to configure")
            }
            let known = Set(config.fields.map(\.key))
            let unknown = values.keys.filter { !known.contains($0) }
            guard unknown.isEmpty else { return failure("Unknown field(s) \(unknown). The fields are: \(known.sorted()).", summary: "Unknown field") }
            BlockConfig.apply(values.mapValues { "\($0)" }, to: module.id, in: model)
            return done(self.module(module.id).map(describe) ?? [:], summary: "Configured \(module.name)")

        case "set_order_and_thread":
            guard let module = module(int(args, "block")) else { return failure("No such block.", summary: "No such block") }
            let order = int(args, "order"), thread = int(args, "thread")
            guard order != nil || thread != nil else { return failure("Give order and/or thread.", summary: "Nothing to change") }
            if let thread { model.updateModuleThread(id: module.id, threadId: thread) }
            if let order { model.updateModuleOrder(id: module.id, order: order) }
            return done(self.module(module.id).map(describe) ?? [:], summary: "Changed the order/thread of \(module.name)")

        case "add_page":
            guard let caption = string(args, "caption"), !caption.trimmingCharacters(in: .whitespaces).isEmpty else { return failure("Give a caption.", summary: "No caption") }
            guard let made = model.addPage(caption: caption, isMacro: (args["macro"] as? NSNumber)?.boolValue ?? false) else {
                return failure("The page could not be added (is the name taken?).", summary: "Could not add the page")
            }
            return done("Added page \"\(made)\" and switched to it.", summary: "Added page \(made)")

        case "delete_page":
            guard let caption = string(args, "caption"), model.deletePage(caption: caption) else {
                return failure("That page does not exist, or is the last one.", summary: "Could not delete the page")
            }
            return done("Deleted page \"\(caption)\".", summary: "Deleted page \(caption)")

        case "go_to_page":
            guard let caption = string(args, "caption"), model.project?.pages.contains(where: { $0.caption == caption }) == true else {
                return failure("No such page.", summary: "No such page")
            }
            model.selectedPage = caption
            return done("Showing \"\(caption)\".", summary: "Went to page \(caption)")

        case "organize_blocks":
            model.organizeBlocks()
            return done("Laid out the page.", summary: "Organized the page")

        case "reset_wire_routing":
            model.resetWireRouting()
            return done("Re-routed the wires.", summary: "Reset wire routing")

        case "add_text":
            guard let text = string(args, "text") else { return failure("Give text.", summary: "No text") }
            guard model.addTextAnnotation(text, at: point()) != nil else { return failure("Could not add the text.", summary: "Could not add text") }
            return done("Added the text.", summary: "Added text \"\(text)\"")

        case "add_shape":
            guard let kind = ["rectangle": PCCGraphicBuilder.Kind.rectangle, "ellipse": .ellipse][(string(args, "kind") ?? "").lowercased()] else {
                return failure("kind is \"rectangle\" or \"ellipse\".", summary: "Bad kind")
            }
            guard model.addShape(kind, at: point()) != nil else { return failure("Could not add the shape.", summary: "Could not add the shape") }
            return done("Added the shape.", summary: "Added a \(string(args, "kind") ?? "shape")")

        case "simulation":
            switch (string(args, "action") ?? "").lowercased() {
            case "play": if model.playsOnHostTimer { model.hostPlay() } else { model.play() }
            case "pause": model.pause()
            case "step":
                guard !model.isPlaying else { return failure("Pause first: a step is one cycle while paused.", summary: "Still playing") }
                model.step()
            case "reset": model.reset()
            case "speed":
                guard let percent = int(args, "speed_percent"), AppModel.speedSteps.contains(Double(percent) / 100) else {
                    return failure("speed_percent is one of 10, 25, 50, 100, 200, 400, 1000.", summary: "Bad speed")
                }
                model.simulationSpeed = Double(percent) / 100
            default: return failure("action is play, pause, step, reset or speed.", summary: "Bad action")
            }
            return done(["playing": model.isPlaying, "tick": Int(model.tickCount), "speed_percent": Int((model.simulationSpeed * 100).rounded())] as [String: Any],
                        summary: "Simulation: \(string(args, "action") ?? "")")

        case "undo":
            guard model.canUndo else { return failure("Nothing to undo.", summary: "Nothing to undo") }
            model.undo()
            return done("Undid the last edit.", summary: "Undid an edit")

        case "redo":
            guard model.canRedo else { return failure("Nothing to redo.", summary: "Nothing to redo") }
            model.redo()
            return done("Redid it.", summary: "Redid an edit")

        case "new_project":
            guard !model.isDocumentEdited else { return failure("The open project has unsaved changes. Save it first, or ask the user.", summary: "Unsaved changes") }
            model.createNewProject()
            return done("Started an empty project.", summary: "Started a new project")

        case "open_project":
            guard let path = string(args, "path") else { return failure("Give a path.", summary: "No path") }
            guard !model.isDocumentEdited else { return failure("The open project has unsaved changes. Save it first, or ask the user.", summary: "Unsaved changes") }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let extensionOK = ["wbp", "pcc", "xml"].contains(url.pathExtension.lowercased())
            guard extensionOK, FileManager.default.fileExists(atPath: url.path) else {
                return failure("No .wbp file at \(url.path) (a legacy .pcc is also accepted).", summary: "No file at \(path)")
            }
            model.loadProject(url: url)
            guard model.project != nil else { return failure("The file could not be read.", summary: "Could not open \(url.lastPathComponent)") }
            return done("Opened \(url.lastPathComponent).", summary: "Opened \(url.lastPathComponent)")

        case "save_project":
            let target: URL
            if let path = string(args, "path") {
                target = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                guard target.pathExtension.lowercased() == "wbp" else { return failure("The file name must end in .wbp.", summary: "Not a .wbp path") }
                // Never over a file that is not this project's own.
                if FileManager.default.fileExists(atPath: target.path), target.standardizedFileURL != model.currentFileURL?.standardizedFileURL {
                    return failure("\(target.path) already exists and is not the open project, so it was not overwritten. Choose another name.", summary: "Would overwrite another file")
                }
            } else if let current = model.currentFileURL, !model.isLegacyDocument {
                target = current
            } else if model.isLegacyDocument {
                return failure("This is a legacy .pcc; give a path ending in .wbp to save the project.", summary: "Legacy project needs a .wbp path")
            } else {
                return failure("The project has no file yet. Give a path ending in .wbp.", summary: "No file yet")
            }
            do { try model.saveProject(to: target) } catch { return failure("Saving failed: \(error.localizedDescription)", summary: "Could not save") }
            return done("Saved \(target.path).", summary: "Saved \(target.lastPathComponent)")

        default:
            return failure("There is no tool called \(name).", summary: "Unknown tool \(name)")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
