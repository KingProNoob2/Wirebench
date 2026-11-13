import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchModel

/// The commands `wirebench_command` accepts. Each takes a JSON object with a `"cmd"` and its own arguments:
///
/// - `open {path}` (at once), `openFile {path}` (asks first if there is something to lose), `requestOpen`, `save {path?}`, `saveAs {path}`,
///   `new`, `answerUnsaved {choice: save|discard|cancel}`, `panelDone`, `panelCancelled`, `quit`
/// - `addPage {caption, macro}`, `deletePage {caption}`, `renamePage {caption, name}`, `renameMacro {page, name}`, `resetWires`, `buildTemplate {path}`
/// - `play`, `pause`, `step`, `reset`, `undo`, `redo`, `organize` (auto-arrange the page)
/// - `drag {ids, dx, dy}` (preview; empty ids clears), `select {ids: [Int]}` (empty clears), `move {ids, dx, dy}`, `delete {ids}`
/// - `addBlock {guid, x?, y?}` → `{id}`
/// - `connect {outModule, outPin, inModule, inPin, inParam?}`, `disconnect {inModule, inPin, inParam?}`: `inParam` names a parameter pin, not an input
/// - `setPage {page}`, `setInput {module, pin, value}`
/// - `inspect {id}` → `{inspector}`, `toggleInput`/`setInputInt`/`setVariable`/`setParam`/`setThread`/`setOrder`/`rename`/`resetState`
/// - `interfacePin {module, op: add|rename|remove, pin?, name?}`: a macro's Inputs/Outputs pins
/// - `config {id}` → `{config}`, `applyConfig {id, values}`: a block's configuration fields and writing them back
/// - `setSetting {key: appearance|snapToGrid|scrollZooms|optimize|pinPitch|cardWidth|macroCallerSpace, value}`
/// - `build` → `{report}`, `export {kind: pbd|csv|dbf|pcc, path}`
/// - `refreshPorts`, `selectPort {path}`, `upload` (opens the port itself, and closes it after)
/// - `plcConfig` → `{plc: {commands, catalogue}}`, `plcAdd {tag?}`, `plcSetCommand {index, tag}`, `plcSetPar {index, which, value}`, `plcRemove {index}`: the PLC configuration; each returns the new `plc`
/// - `selectMany {ids, graphics}` (blocks and shapes at once), `selectGraphic {indices}`, `dragGraphic`/`moveGraphic {indices, dx, dy}`, `resizeShape {index, w, h}`,
///   `addShape {kind: rectangle|ellipse, x?, y?}`, `addText {text?, x?, y?}`, `editText {index, text}`, `deleteGraphic {indices}`
/// - `palette {query?}` → `{blocks: [{guid, name, category, summary}]}`
/// - the block reference: `helpState` → `{state}` (the list for the search, the open page, and the window's words in the chosen language),
///   `helpSetLanguage {value: en|cs}`, `helpSetQuery {value}`, `helpSelect {name}`, `helpShowBlock {id}` (opens the page for that block's type)
/// - the agent panel: `agentState` → `{state}`, `agentSetProvider {id}`, `agentSetModel {value}`, `agentSetBaseURL {value}`, `agentSetKey {value}`,
///   `agentRemoveKey`, `agentSend {text}`, `agentSetCanEdit {value}` (whether the agent may change the project), `agentClear`, `agentRefreshModels` (the list is in the state, fetched from the service). The key is held in the system's secret store and never returned.
@MainActor
enum BridgeCommands {
    /// The PLC configuration as the Qt dialog draws it: the entries with their guide, and the commands the profile offers.
    @MainActor
    private static func plcState(_ model: AppModel) -> [String: Any] {
        let entries: [[String: Any]] = model.plcCommands.enumerated().map { index, entry in
            let info = model.plcCommandInfo(of: entry)
            let guide = model.plcGuide(of: entry)
            var item: [String: Any] = [
                "index": index, "word": String(format: "0x%04X", entry.plcCommandWord), "listed": guide != nil,
                "tag": info?.selectionTag ?? "", "title": info?.title ?? "Command",
                "summary": guide?.summary ?? "This hardware profile does not list this command; it is kept as it is.",
            ]
            item["params"] = (0..<2).map { slot -> [String: Any] in
                let parameter = guide?.parameters[slot] ?? .unlisted(slot + 1)
                var out: [String: Any] = [
                    "which": slot + 1, "name": parameter.name, "dataType": parameter.dataType, "used": parameter.isUsed,
                    "meaning": parameter.meaning, "value": entry.plcParameter(slot + 1),
                    "presets": parameter.presets.map { ["label": $0.label, "value": $0.value] },
                ]
                if let bits = parameter.bits {
                    out["bits"] = ["names": bits.names, "fixed": bits.fixed, "onLabel": bits.onLabel, "offLabel": bits.offLabel]
                }
                return out
            }
            return item
        }
        return ["commands": entries, "profile": model.plcProfileName, "profiles": model.plcProfileNames,
                "catalogue": model.systemCommandCatalogue.map { ["tag": $0.selectionTag, "title": $0.title, "word": String(format: "0x%04X", $0.command)] }]
    }

    private static func int(_ arguments: [String: Any], _ key: String) -> Int? { (arguments[key] as? NSNumber)?.intValue }
    private static func double(_ arguments: [String: Any], _ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue }

    static func run(_ arguments: [String: Any], in session: BridgeSession) -> [String: Any] {
        let model = session.model
        switch arguments["cmd"] as? String ?? "" {
        case "open":
            guard let path = arguments["path"] as? String else { return ["ok": false, "error": "no path"] }
            model.loadProject(url: URL(fileURLWithPath: path))
            return ["ok": model.project != nil]
        case "save":
            do {
                if let path = arguments["path"] as? String { try model.saveProject(to: URL(fileURLWithPath: path)) }
                else { model.saveProject() }
                return ["ok": true]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case "new": model.createNewProject()           // asks first (the scene's `question`) when there is something to lose
        case "requestOpen": model.openProjectFile()    // likewise; then the scene's `panel` is `open`
        case "openFile":
            guard let path = arguments["path"] as? String else { return ["ok": false] }
            model.openProjectFromFinder(URL(fileURLWithPath: path))
        case "saveAs":
            guard let path = arguments["path"] as? String else { return ["ok": false] }
            model.didChooseSaveURL(URL(fileURLWithPath: path))
            model.pendingFilePanel = nil
        case "panelDone": model.pendingFilePanel = nil
        case "panelCancelled": model.pendingFilePanel = nil; model.savePanelWasCancelled()
        case "answerUnsaved":
            let choice: AppModel.UnsavedChoice = ["save": .save, "discard": .discard][arguments["choice"] as? String ?? ""] ?? .cancel
            model.answerUnsavedChanges(choice)
        case "quit":
            // Quits at once when nothing would be lost; otherwise the scene's `question` asks, and `quit` turns true after the answer.
            if model.shouldTerminateNow() { session.quitRequested = true }
        case "addPage":
            let macro = (arguments["macro"] as? NSNumber)?.boolValue ?? false
            guard let caption = model.addPage(caption: arguments["caption"] as? String ?? "", isMacro: macro) else { return ["ok": false] }
            return ["ok": true, "caption": caption]
        case "deletePage":
            return ["ok": model.deletePage(caption: arguments["caption"] as? String ?? "")]
        case "renamePage":
            return ["ok": model.renamePage(arguments["caption"] as? String ?? arguments["page"] as? String ?? "",
                                           to: arguments["name"] as? String ?? "")]
        case "renameMacro":
            // The older command, which only ever renamed macro sheets; the front ends use `renamePage` for both kinds.
            return ["ok": model.renameMacroPage(arguments["page"] as? String ?? "", to: arguments["name"] as? String ?? "")]
        case "resetWires": model.resetWireRouting()
        case "buildTemplate":
            guard let path = arguments["path"] as? String else { return ["ok": false] }
            model.loadBuildTemplate(from: URL(fileURLWithPath: path))
        case "play": model.hostPlay()
        case "pause": model.pause()
        case "step": model.step()
        case "reset": model.reset()
        case "organize": model.organizeBlocks()          // the SwiftUI app's Organize Blocks: a layered layout of the page
        case "copy": model.copySelection()
        case "cut": model.cutSelection()
        case "paste": model.paste()
        case "undo": model.undo()
        case "redo": model.redo()
        case "select":
            var ids = Set((arguments["ids"] as? [Int]) ?? [])
            // A name selects by block name, which is how a script or a screenshot refers to one.
            if let name = arguments["name"] as? String, let module = model.project?.modules.first(where: { $0.name == name }) {
                ids = [module.id]
            }
            model.selectedModuleIds = ids
            model.selectedModuleId = ids.first
            model.selectedAnnotationIndices = []
            model.selectedAnnotationIndex = nil
        case "move":
            let ids = Set((arguments["ids"] as? [Int]) ?? [])
            guard let lead = ids.min() else { break }
            session.dragOffsets = [:]
            model.moveModules(ids, lead: lead, deltaX: double(arguments, "dx") ?? 0, deltaY: double(arguments, "dy") ?? 0)
        case "drag":
            // Shows blocks moved without committing it; `move` commits, an empty `ids` clears.
            let delta = CGSize(width: double(arguments, "dx") ?? 0, height: double(arguments, "dy") ?? 0)
            session.dragOffsets = Dictionary(uniqueKeysWithValues: ((arguments["ids"] as? [Int]) ?? []).map { ($0, delta) })
        case "selectMany":
            // A marquee's result: blocks and shapes together.
            let ids = Set((arguments["ids"] as? [Int]) ?? [])
            let graphics = Set((arguments["graphics"] as? [Int]) ?? [])
            model.selectedModuleIds = ids
            model.selectedModuleId = ids.sorted().first
            model.selectedAnnotationIndices = graphics
            model.selectedAnnotationIndex = graphics.sorted().first
        case "selectGraphic":
            let indices = Set((arguments["indices"] as? [Int]) ?? [])
            model.selectedModuleIds = []
            model.selectedModuleId = nil
            model.selectedAnnotationIndices = indices
            model.selectedAnnotationIndex = indices.first
        case "dragGraphic":
            let delta = CGSize(width: double(arguments, "dx") ?? 0, height: double(arguments, "dy") ?? 0)
            session.graphicDrag = Dictionary(uniqueKeysWithValues: ((arguments["indices"] as? [Int]) ?? []).map { ($0, delta) })
        case "moveGraphic":
            let indices = Set((arguments["indices"] as? [Int]) ?? [])
            session.graphicDrag = [:]
            if let lead = indices.first {
                model.moveShapes(indices, lead: lead, deltaX: double(arguments, "dx") ?? 0, deltaY: double(arguments, "dy") ?? 0)
            }
        case "resizeShape":
            guard let index = int(arguments, "index"), let w = double(arguments, "w"), let h = double(arguments, "h"),
                  let box = model.project?.graphics[safe: index]?.boundingBox else { return ["ok": false] }
            return ["ok": model.updateShape(at: index, to: GraphicBox(x: box.x, y: box.y, width: w, height: h))]
        case "addShape":
            let kind: PCCGraphicBuilder.Kind = (arguments["kind"] as? String) == "ellipse" ? .ellipse : .rectangle
            let point = double(arguments, "x").flatMap { x in double(arguments, "y").map { CGPoint(x: x, y: $0) } }
            guard let index = model.addShape(kind, at: point) else { return ["ok": false] }
            model.selectedModuleIds = []; model.selectedModuleId = nil
            return ["ok": true, "index": index]
        case "addText":
            let point = double(arguments, "x").flatMap { x in double(arguments, "y").map { CGPoint(x: x, y: $0) } }
            guard let index = model.addTextAnnotation(arguments["text"] as? String ?? "Text", at: point) else { return ["ok": false] }
            model.selectedModuleIds = []; model.selectedModuleId = nil
            model.editingAnnotationIndex = nil
            return ["ok": true, "index": index]
        case "editText":
            guard let index = int(arguments, "index"), let text = arguments["text"] as? String else { return ["ok": false] }
            model.updateAnnotationText(at: index, text: text)
        case "deleteGraphic":
            for index in ((arguments["indices"] as? [Int]) ?? []).sorted(by: >) { model.deleteAnnotation(at: index) }
        case "delete":
            for id in (arguments["ids"] as? [Int]) ?? [] { _ = model.deleteModule(id: id) }
        case "addBlock":
            guard let text = arguments["guid"] as? String, let guid = UUID(uuidString: text) else { return ["ok": false] }
            let point = double(arguments, "x").flatMap { x in double(arguments, "y").map { CGPoint(x: x, y: $0) } }
            guard let id = model.addBlock(guid: guid, at: point) else { return ["ok": false] }
            return ["ok": true, "id": id]
        case "connect":
            guard let om = int(arguments, "outModule"), let op = int(arguments, "outPin"),
                  let im = int(arguments, "inModule"), let ip = int(arguments, "inPin") else { return ["ok": false] }
            let side: PinSide = (arguments["inParam"] as? Bool) == true ? .param : .input
            return ["ok": model.connectPins(from: PinReference(moduleId: om, side: .output, index: op),
                                            to: PinReference(moduleId: im, side: side, index: ip))]
        case "disconnect":
            guard let im = int(arguments, "inModule"), let ip = int(arguments, "inPin") else { return ["ok": false] }
            let side: PinSide = (arguments["inParam"] as? Bool) == true ? .param : .input
            return ["ok": model.disconnectPin(PinReference(moduleId: im, side: side, index: ip))]
        case "setPage":
            if let page = arguments["page"] as? String { model.selectedPage = page }
        case "setInput":
            guard let module = int(arguments, "module"), let pin = int(arguments, "pin"),
                  let value = double(arguments, "value") else { return ["ok": false] }
            let current = model.getNode(id: module)?.block.inPins[safe: pin]
            if case .bool = current { model.setModuleInput(moduleId: module, pinIndex: pin, value: .bool(value != 0)) }
            else {
                // A JSON number is a Double; converting it straight to Int32 traps out of range and on NaN.
                let clamped = min(max(value.isFinite ? value : 0, -2_000_000_000), 2_000_000_000)
                model.setModuleInput(moduleId: module, pinIndex: pin, value: .int32(Int32(clamped.rounded())))
            }
        case "inspect":
            guard let id = int(arguments, "id"), let snapshot = InspectorSnapshot.make(of: model, moduleId: id),
                  let data = try? JSONEncoder().encode(snapshot),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return ["ok": false] }
            return ["ok": true, "inspector": object]
        case "config":
            guard let id = int(arguments, "id"), let config = BlockConfig.make(of: model, moduleId: id),
                  let data = try? JSONEncoder().encode(config),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return ["ok": false] }
            return ["ok": true, "config": object]
        case "applyConfig":
            guard let id = int(arguments, "id"), let values = arguments["values"] as? [String: Any] else { return ["ok": false] }
            BlockConfig.apply(values.mapValues { "\($0)" }, to: id, in: model)
        case "interfacePin":
            // Edits a macro's Inputs/Outputs block immediately: add, rename or remove a pin.
            guard let m = int(arguments, "module") else { return ["ok": false] }
            switch arguments["op"] as? String ?? "" {
            case "add": model.addInterfacePin(moduleId: m)
            case "rename":
                guard let pin = int(arguments, "pin"), let name = arguments["name"] as? String else { return ["ok": false] }
                model.renameInterfacePin(moduleId: m, pin: pin, to: name)
            case "remove":
                guard let pin = int(arguments, "pin") else { return ["ok": false] }
                model.removeInterfacePin(moduleId: m, pin: pin)
            default: return ["ok": false]
            }
        case "toggleInput":
            guard let m = int(arguments, "module"), let p = int(arguments, "pin") else { return ["ok": false] }
            model.toggleModuleInput(moduleId: m, pinIndex: p)
        case "pressInput":      // a push button's two edges: held, then let go
            guard let m = int(arguments, "module"), let p = int(arguments, "pin"), let down = arguments["down"] as? Bool else { return ["ok": false] }
            model.setModuleInputPressed(moduleId: m, pinIndex: p, isPressed: down)
        case "setInputInt":
            guard let m = int(arguments, "module"), let p = int(arguments, "pin"), let v = int(arguments, "value") else { return ["ok": false] }
            // Keep the pin's own width, as the SwiftUI inspector does.
            switch model.getNode(id: m)?.block.inPins[safe: p] {
            case .int16: model.setModuleInput(moduleId: m, pinIndex: p, value: .int16(Int16(truncatingIfNeeded: v)))
            case .int64: model.setModuleInput(moduleId: m, pinIndex: p, value: .int64(Int64(v)))
            default: model.setModuleInput(moduleId: m, pinIndex: p, value: .int32(Int32(truncatingIfNeeded: v)))
            }
        case "setVariable":
            guard let m = int(arguments, "module"), let v = int(arguments, "value") else { return ["ok": false] }
            model.setVariableValue(moduleId: m, value: v)
        case "setParam":
            guard let m = int(arguments, "module"), let p = int(arguments, "pin"),
                  let text = arguments["text"] as? String, let v = Int32(text.trimmingCharacters(in: .whitespaces)) else { return ["ok": false] }
            model.updateModuleParam(id: m, paramIndex: p, value: .int32(v))
        case "setThread":
            guard let m = int(arguments, "module"), let v = int(arguments, "value") else { return ["ok": false] }
            model.updateModuleThread(id: m, threadId: v)
        case "setOrder":
            guard let m = int(arguments, "module"), let v = int(arguments, "value") else { return ["ok": false] }
            model.updateModuleOrder(id: m, order: v)
        case "rename":
            guard let m = int(arguments, "module"), let name = arguments["name"] as? String else { return ["ok": false] }
            model.renameModule(id: m, name: name)
        case "resetState":
            guard let m = int(arguments, "module") else { return ["ok": false] }
            model.resetModuleState(id: m)
        case "setSetting":
            // `appearance` is system|light|dark; the others are booleans (1/0).
            let on = (arguments["value"] as? NSNumber)?.boolValue ?? false
            switch arguments["key"] as? String ?? "" {
            case "appearance":
                guard let mode = (arguments["value"] as? String).flatMap(AppearanceMode.init(rawValue:)) else { return ["ok": false] }
                model.appearance = mode
            case "snapToGrid": model.snapToGrid = on
            case "scrollZooms": model.scrollZooms = on
            case "optimize": model.optimizeProgram = on
            case "speed":
                // One of `AppModel.speedSteps`, as the SwiftUI slider offers.
                if let speed = double(arguments, "value"), AppModel.speedSteps.contains(speed) { model.simulationSpeed = speed }
            case "macroCallerSpace":
                if let space = double(arguments, "value") { CardGeometry.macroCallerSpace = CGFloat(min(40, max(0, space))) }
            case "cardWidth":
                if let width = double(arguments, "value") { CardGeometry.defaultWidth = CGFloat(min(220, max(110, width))) }
            case "pinPitch":
                // How far apart pin rows are drawn; wires and pin positions follow. Between 14 and 32.
                if let pitch = double(arguments, "value") { CardGeometry.pinPitch = CGFloat(min(32, max(14, pitch))) }
            default: return ["ok": false]
            }
        case "build":
            guard let report = model.compileProject() else { return ["ok": false] }
            return ["ok": true, "report": [
                "summary": report.summary, "modules": report.moduleCount, "compiled": report.compiledModules,
                "display": report.displayModules, "recordBytes": report.recordBytes, "dataSlots": report.dataSlots,
                "terminals": report.terminals, "symbolRows": report.symbolRows, "unshaped": report.unshaped,
                "macros": report.macros, "tableBytes": report.table.count] as [String: Any]]
        case "export":
            // What a build can be written as: the program binary, the symbol table, the variables, or the legacy project.
            guard let path = arguments["path"] as? String else { return ["ok": false, "error": "no path"] }
            let url = URL(fileURLWithPath: path)
            if model.buildReport == nil, (arguments["kind"] as? String) != "pcc" { _ = model.compileProject() }
            switch arguments["kind"] as? String ?? "" {
            case "pbd": model.finishProgramBinaryExport(to: url)
            case "csv": model.finishSymbolTableExport(to: url)
            case "dbf": model.finishProgramVariablesExport(to: url)
            case "pcc": model.exportForDirigo(); model.finishExport(to: url); model.pendingFilePanel = nil
            default: return ["ok": false, "error": "unknown export"]
            }
        case "refreshPorts": model.refreshPorts()
        case "selectPort": model.selectedPortPath = arguments["path"] as? String ?? ""
        case "upload": model.uploadCompiledProgram()
        case "plcConfig":
            return ["ok": true, "plc": plcState(model)]
        case "plcAdd":
            let info = (arguments["tag"] as? String).flatMap { tag in model.systemCommandCatalogue.first { $0.selectionTag == tag } }
            model.addPLCCommand(info)
            return ["ok": true, "plc": plcState(model)]
        case "plcSetCommand":
            if let index = int(arguments, "index"), let tag = arguments["tag"] as? String,
               let info = model.systemCommandCatalogue.first(where: { $0.selectionTag == tag }) { model.setPLCCommand(at: index, to: info) }
            return ["ok": true, "plc": plcState(model)]
        case "plcSetPar":
            if let index = int(arguments, "index"), let which = int(arguments, "which"), let value = int(arguments, "value") {
                model.setPLCParameter(at: index, which, value: value)
            }
            return ["ok": true, "plc": plcState(model)]
        case "plcSetProfile":
            if let name = arguments["name"] as? String { model.setPLCProfile(name) }
            return ["ok": true, "plc": plcState(model)]
        case "plcRemove":
            if let index = int(arguments, "index") { model.removePLCCommand(at: index) }
            return ["ok": true, "plc": plcState(model)]
        case "agentState":
#if WIREBENCH_AI
            let agent = model.agent
            return ["ok": true, "state": [
                "presets": agent.presets.map { ["id": $0.id, "name": $0.name, "needsKey": $0.needsKey, "keyHelp": $0.keyHelp] },
                "provider": agent.providerID, "model": agent.model, "baseURL": agent.baseURL,
                "custom": agent.providerID == AgentPreset.custom.id, "needsKey": agent.preset.needsKey,
                "keyHelp": agent.preset.keyHelp, "hasKey": agent.hasKey, "keyLocation": agent.keyLocation,
                "sending": agent.isSending, "error": agent.error, "blocker": agent.blocker ?? "",
                "models": agent.availableModels, "loadingModels": agent.isLoadingModels, "modelsError": agent.modelsError,
                "modelsHint": agent.modelsHint,
                "canEdit": agent.canEdit, "toolsRefused": agent.toolsRefused, "toolsRefusal": agent.toolsRefusal, "currentAction": agent.currentAction,
                "messages": agent.messages.map { ["role": $0.role.rawValue, "text": $0.text, "failed": $0.failed] },
            ] as [String: Any]]
#else
            // The agent is a build option, off by default: the Qt panel gets a state it can draw as unavailable, with
            // every field it binds to present and empty rather than undefined.
            return ["ok": true, "state": [
                "available": false, "presets": [] as [[String: Any]], "provider": "", "model": "", "baseURL": "",
                "custom": false, "needsKey": false, "keyHelp": "", "hasKey": false, "keyLocation": "",
                "sending": false, "error": "", "blocker": "", "models": [] as [String], "loadingModels": false,
                "modelsError": "", "modelsHint": "", "canEdit": false, "toolsRefused": false, "toolsRefusal": "",
                "currentAction": "", "messages": [] as [[String: Any]],
            ] as [String: Any]]
#endif
        case "helpState":
            let help = model.help
            let strings = help.strings
            var state: [String: Any] = [
                "language": help.language.rawValue, "languages": HelpLanguage.allCases.map { ["id": $0.rawValue, "label": $0.label] },
                "query": help.query, "selected": help.selected ?? "", "isFallback": help.isFallback,
                "strings": [
                    "title": strings.title, "search": strings.search, "pins": strings.pins, "abbreviation": strings.abbreviation,
                    "kind": strings.kind, "dataType": strings.dataType, "name": strings.name, "description": strings.description,
                    "defaultValue": strings.defaultValue, "notes": strings.notes, "noResults": strings.noResults, "noPage": strings.noPage,
                    "notTranslated": strings.notTranslated, "pickABlock": strings.pickABlock, "source": strings.source,
                ],
                "sections": help.sections.map { section in
                    ["title": section.title, "entries": section.entries.map { ["name": $0.name, "title": $0.title] }] as [String: Any]
                },
            ]
            if let entry = help.entry {
                state["entry"] = [
                    "name": entry.name, "category": entry.category, "group": entry.group, "title": entry.title, "formula": entry.formula,
                    "pins": entry.pins.map { ["abbreviation": $0.abbreviation, "kind": strings.kind($0.kind), "dataType": $0.dataType,
                                              "name": $0.name, "text": $0.text, "defaultValue": $0.defaultValue] },
                    "notes": entry.notes, "tables": entry.tables.map { ["head": $0.head, "rows": $0.rows] },
                ] as [String: Any]
            }
            return ["ok": true, "state": state]
        case "helpSetLanguage": model.help.language = HelpLanguage(rawValue: arguments["value"] as? String ?? "") ?? model.help.language
        case "helpSetQuery": model.help.query = arguments["value"] as? String ?? ""
        case "helpSelect": model.help.selected = arguments["name"] as? String
        // The page for a block of the project, by its id: what "Help" in a block's menu and in the inspector open.
        case "helpShowBlock":
            if let id = int(arguments, "id"), let module = model.module(id: id) { model.help.show(blockNamed: HelpModel.blockName(of: module)) }
#if WIREBENCH_AI
        case "agentSetProvider": model.agent.providerID = arguments["id"] as? String ?? model.agent.providerID
        case "agentSetModel": model.agent.model = arguments["value"] as? String ?? model.agent.model
        case "agentSetBaseURL": model.agent.baseURL = arguments["value"] as? String ?? model.agent.baseURL
        case "agentSetKey": model.agent.setKey(arguments["value"] as? String ?? "")
        case "agentRemoveKey": model.agent.removeKey()
        case "agentSend": model.agent.send(arguments["text"] as? String ?? "")
        case "agentSetCanEdit": model.agent.canEdit = arguments["value"] as? Bool ?? model.agent.canEdit
        case "agentClear": model.agent.clear()
        case "agentRefreshModels": model.agent.refreshModels()
#else
        case "agentSetProvider", "agentSetModel", "agentSetBaseURL", "agentSetKey", "agentRemoveKey",
             "agentSend", "agentSetCanEdit", "agentClear", "agentRefreshModels":
            return ["ok": false, "error": "the agent is not built in"]
#endif
        case "palette":
            let query = arguments["query"] as? String ?? ""
            // The SwiftUI picker's scope and order: every catalogue type but the bare macro ones, best match first, ties going to
            // the block likelier to be added next (what was added before, the selected block, what is on the page), and with no
            // query the likeliest first.
            let scope = BlockTypeCatalog.all.filter(BlockPaletteSearch.isOffered)
            let chances = model.blockUsage.probabilities(for: scope, in: model.blockSuggestionContext)
            let ranked = BlockPaletteSearch.ranked(scope, for: query, chances: chances, byChanceWithoutQuery: true)
            return ["ok": true, "blocks": ranked.map { info in
                ["guid": info.guid.uuidString, "name": info.blockName,
                 "category": BlockPaletteSearch.displayName(for: info.category), "summary": info.summary]
            }]
        default:
            return ["ok": false, "error": "unknown command"]
        }
        return ["ok": true]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
