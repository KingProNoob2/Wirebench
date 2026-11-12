#if WIREBENCH_AI
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// The agent's hands (`AgentToolbox`) on a real project, and the loop that lets a model use them.
/// Nested in `AgentTests` so it runs one test at a time with them: they share the stubbed network.
extension AgentTests {
@MainActor
@Suite("Agent tools")
struct ToolTests {
    /// A model with an empty project and a toolbox on it.
    private func make() -> (AppModel, AgentToolbox) {
        let model = AppModel(defaults: AgentTests.defaults())
        model.createNewProject()
        return (model, AgentToolbox(model: model))
    }

    private func run(_ box: AgentToolbox, _ name: String, _ args: [String: Any] = [:], canEdit: Bool = true) -> AgentToolOutcome {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return box.run(name: name, arguments: json, canEdit: canEdit)
    }

    private func object(_ outcome: AgentToolOutcome) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(outcome.result.utf8))) as? [String: Any] ?? [:]
    }

    @Test("Every tool has a name, a description and a schema that is a JSON object, and only reading tools are offered when editing is off")
    func catalogue() throws {
        let all = AgentToolbox.reading + AgentToolbox.editing
        #expect(Set(all.map(\.name)).count == all.count, "names are unique")
        for tool in all {
            #expect(!tool.summary.isEmpty)
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(tool.schema.utf8)) as? [String: Any])
            #expect(schema["type"] as? String == "object", "\(tool.name)")
            // OpenAI refuses a schema with an empty `required` ("[] is too short"), and one naming a property that is not there.
            let properties = schema["properties"] as? [String: Any] ?? [:]
            if let required = schema["required"] as? [String] {
                #expect(!required.isEmpty, "\(tool.name): an empty required list is left out")
                #expect(required.allSatisfy { properties[$0] != nil }, "\(tool.name): required names a property that is not there")
            } else {
                #expect(schema["required"] == nil, "\(tool.name)")
            }
            #expect(tool.summary.count <= 1024, "\(tool.name): OpenAI cuts descriptions off at 1024 characters")
            let api = tool.apiObject
            #expect(api["type"] as? String == "function")
        }
        #expect(AgentToolbox.reading.allSatisfy { !$0.changes })
        #expect(AgentToolbox.editing.allSatisfy { $0.changes })
        #expect(AgentToolbox.offered(canEdit: false).map(\.name) == AgentToolbox.reading.map(\.name))
        #expect(AgentToolbox.offered(canEdit: true).count == all.count)
        // Nothing reaches the hardware or the settings.
        for tool in all { #expect(!["upload", "connect_plc", "serial", "settings"].contains { tool.name.contains($0) }) }
    }

    @Test("The agent is not given SystemCmd to add: the PLC's commands are the user's PLC Configuration")
    func systemCmdIsNotABlockToAdd() {
        let (model, box) = make()
        let outcome = run(box, "add_block", ["type": "SystemCmd"])
        #expect(outcome.result.contains("PLC Configuration"))
        #expect(model.project?.modules.contains { $0.guid == SystemCmdBlock.guid } == false)
    }

    @Test("A tool that changes something is refused when editing is off, and nothing changes")
    func refusedWhenOff() {
        let (model, box) = make()
        let before = model.project?.modules.count
        let outcome = run(box, "add_block", ["type": "And"], canEdit: false)
        #expect(outcome.failed)
        #expect(outcome.result.contains("turned off"))
        #expect(model.project?.modules.count == before)
        #expect(!run(box, "project_overview", canEdit: false).failed, "reading is always allowed")
    }

    @Test("An unknown tool, and arguments that are not JSON, are errors the model can read")
    func badCalls() {
        let (keep, box) = make(); defer { withExtendedLifetime(keep) {} }
        #expect(box.run(name: "make_coffee", arguments: "{}", canEdit: true).failed)
        #expect(box.run(name: "read_page", arguments: "not json", canEdit: true).failed)
        #expect(!box.run(name: "read_page", arguments: "", canEdit: true).failed, "no arguments is an empty object")
    }

    @Test("Blocks are added by name, wired by pin index, read back, and one Undo takes each edit away")
    func buildAndRead() async throws {
        let (model, box) = make()
        let a = run(box, "add_block", ["type": "boolvar", "x": 40, "y": 40, "name": "Start"])      // any case
        #expect(!a.failed, Comment(rawValue: a.result))
        let b = run(box, "add_block", ["type": "Not", "x": 240, "y": 40])
        #expect(!b.failed)
        let aID = object(a)["id"] as? Int, bID = object(b)["id"] as? Int
        #expect(aID != nil && bID != nil && aID != bID)
        #expect(object(a)["name"] as? String == "Start")
        #expect((object(b)["in"] as? [String])?.isEmpty == false, "the new block's pins come back, ready to wire")

        let wired = run(box, "connect", ["from_block": aID!, "from_pin": 0, "to_block": bID!, "to_pin": 0])
        #expect(!wired.failed, Comment(rawValue: wired.result))
        let page = object(run(box, "read_page"))
        #expect((page["blocks"] as? [[String: Any]])?.count == 2)
        #expect(page["wires"] as? [String] == ["\(aID!):0>\(bID!):0"])

        #expect(!run(box, "disconnect", ["to_block": bID!, "to_pin": 0]).failed)
        #expect(run(box, "disconnect", ["to_block": bID!, "to_pin": 0]).failed, "nothing is left to remove")

        #expect(!run(box, "rename_block", ["block": bID!, "name": "Inverter"]).failed)
        #expect(model.module(id: bID!)?.name == "Inverter")
        #expect(!run(box, "move_block", ["block": bID!, "x": 400, "y": 120]).failed)
        #expect(model.module(id: bID!)?.x == 400 && model.module(id: bID!)?.y == 120)

        try await Task.sleep(nanoseconds: 400_000_000)     // edits made together are one Undo step; this one stands apart
        #expect(!run(box, "delete_blocks", ["blocks": [aID!, bID!]]).failed)
        #expect(model.project?.modules.isEmpty == true)
        #expect(!run(box, "undo").failed)
        #expect(model.project?.modules.count == 2, "Undo brings the deleted blocks back")
    }

    @Test("A wire that cannot be made says why, and lists the real pins")
    func connectErrors() {
        let (model, box) = make()
        let a = object(run(box, "add_block", ["type": "BoolVar"]))["id"] as! Int
        let b = object(run(box, "add_block", ["type": "Not"]))["id"] as! Int
        let tooHigh = run(box, "connect", ["from_block": a, "from_pin": 9, "to_block": b, "to_pin": 0])
        #expect(tooHigh.failed && tooHigh.result.contains("output"))
        let noBlock = run(box, "connect", ["from_block": a, "from_pin": 0, "to_block": 999, "to_pin": 0])
        #expect(noBlock.failed)
        let itself = run(box, "connect", ["from_block": a, "from_pin": 0, "to_block": a, "to_pin": 0])
        #expect(itself.failed)
        #expect(model.project?.inConnections.isEmpty == true, "failed calls leave no wire behind")
        #expect(run(box, "add_block", ["type": "NoSuchBlockType"]).failed)
        #expect(run(box, "delete_blocks", ["blocks": [a, 999]]).failed)
        #expect(model.project?.modules.count == 2, "a delete with one bad id deletes nothing")
    }

    @Test("Values: a BoolVar switches, an unwired input is set, a bad pin is refused")
    func values() {
        let (model, box) = make()
        let v = object(run(box, "add_block", ["type": "BoolVar"]))["id"] as! Int
        #expect(!run(box, "set_variable", ["block": v, "value": 1]).failed)
        let snapshot = InspectorSnapshot.make(of: model, moduleId: v)
        #expect(snapshot != nil)
        let n = object(run(box, "add_block", ["type": "Not"]))["id"] as! Int
        #expect(run(box, "set_variable", ["block": n, "value": 1]).failed, "Not is not a variable")
        #expect(!run(box, "set_input_value", ["block": n, "pin": 0, "value": 0]).failed)
        #expect(run(box, "set_input_value", ["block": n, "pin": 50, "value": 0]).failed)
        #expect(run(box, "set_param", ["block": n, "pin": 0, "value": 1]).failed, "Not has no parameters")
    }

    @Test("Pages: added, shown, listed in the overview, deleted")
    func pages() {
        let (model, box) = make()
        #expect(!run(box, "add_page", ["caption": "*helper", "macro": true]).failed)
        #expect(model.selectedPage == "*helper")
        let pages = object(run(box, "project_overview"))["pages"] as? [[String: Any]]
        #expect(pages?.contains { $0["caption"] as? String == "*helper" && $0["macro"] as? Bool == true } == true)
        #expect(!run(box, "go_to_page", ["caption": "main"]).failed)
        #expect(model.selectedPage == "main")
        #expect(run(box, "go_to_page", ["caption": "nowhere"]).failed)
        #expect(run(box, "read_page", ["page": "nowhere"]).failed)
        #expect(!run(box, "delete_page", ["caption": "*helper"]).failed)
    }

    @Test("The library can be searched, and a block's reference read, by name")
    func lookup() {
        let (keep, box) = make(); defer { withExtendedLifetime(keep) {} }
        let found = object(run(box, "find_block_types", ["query": "counter"]))
        let types = (found["blocks"] as? [[String: Any]])?.compactMap { $0["type"] as? String } ?? []
        #expect(types.contains { $0.lowercased().contains("counter") })
        #expect(run(box, "find_block_types", ["query": "zzzzzz"]).result.contains("No block matches"))
        let help = run(box, "block_help", ["type": "Counter"])
        #expect(!help.failed && help.result.contains("Pins"), "the reference lists the pins")
        #expect(run(box, "block_help", ["type": "NoSuch"]).failed)
    }

    @Test("Every block type the library offers has a reference the agent can read")
    func everyBlockHasAReference() {
        let (keep, box) = make(); defer { withExtendedLifetime(keep) {} }
        // The original's help has no page for these, so there is nothing to condense: `Generic` and `Unresolved` are placeholders, the rest
        // are blocks the help never documented. A block not in this list that loses its reference fails here.
        let undocumented: Set<String> = ["FloatMath", "Generic", "IQRF", "Switch2", "Switch8", "Unresolved"]
        let missing = BlockTypeCatalog.all.map(\.blockName).filter { !undocumented.contains($0) && run(box, "block_help", ["type": $0]).failed }
        #expect(missing.isEmpty, "no reference for: \(missing.sorted())")
        #expect(run(box, "block_help", ["type": "Segment"]).result.contains("DP"), "Segment's pins are listed")
    }

    @Test("A block's configuration fields come back from read_block, and an unknown one is refused")
    func configure() {
        let (keep, box) = make(); defer { withExtendedLifetime(keep) {} }
        let id = object(run(box, "add_block", ["type": "And"]))["id"] as! Int
        let block = object(run(box, "read_block", ["block": id]))
        #expect((block["inputs"] as? [[String: Any]])?.isEmpty == false)
        let bad = run(box, "configure_block", ["block": id, "values": ["nonsense": "1"]])
        #expect(bad.failed && bad.result.contains("fields"))
    }

    @Test("Saving never overwrites a file that is not the open project's own, and opening refuses unsaved changes")
    func files() throws {
        let (model, box) = make()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = folder.appendingPathComponent("other.pcc")
        try "keep me".write(to: other, atomically: true, encoding: .utf8)

        #expect(run(box, "save_project").failed, "a project with no file needs a path")
        #expect(run(box, "save_project", ["path": other.path]).failed)
        #expect(try String(contentsOf: other, encoding: .utf8) == "keep me", "the other file is untouched")
        #expect(run(box, "save_project", ["path": folder.appendingPathComponent("x.txt").path]).failed, "only .pcc")

        _ = run(box, "add_block", ["type": "And"])
        let mine = folder.appendingPathComponent("mine.pcc")
        #expect(!run(box, "save_project", ["path": mine.path]).failed)
        #expect(FileManager.default.fileExists(atPath: mine.path))
        #expect(!run(box, "save_project").failed, "now it has a file, which it may overwrite")

        _ = run(box, "add_block", ["type": "Not"])
        #expect(model.isDocumentEdited)
        #expect(run(box, "open_project", ["path": mine.path]).failed, "unsaved changes")
        #expect(run(box, "new_project").failed, "unsaved changes")
        _ = run(box, "save_project")
        #expect(!run(box, "open_project", ["path": mine.path]).failed)
        #expect(model.project?.modules.count == 2)
        #expect(run(box, "open_project", ["path": folder.appendingPathComponent("missing.pcc").path]).failed)
    }

    @Test("A project that is built and run reports its state: step moves the tick count, reset returns it")
    func simulation() {
        let (model, box) = make()
        _ = run(box, "add_block", ["type": "BoolVar"])
        #expect(run(box, "simulation", ["action": "dance"]).failed)
        #expect(run(box, "simulation", ["action": "speed", "speed_percent": 123]).failed)
        #expect(!run(box, "simulation", ["action": "speed", "speed_percent": 400]).failed)
        #expect(model.simulationSpeed == 4)
        #expect(!run(box, "simulation", ["action": "pause"]).failed)
        let before = model.tickCount
        _ = run(box, "simulation", ["action": "step"])
        #expect(model.tickCount >= before)
        _ = run(box, "simulation", ["action": "reset"])
        #expect(model.tickCount == 0)
    }

    @Test("With no project open only the tools that do not need one work")
    func noProject() {
        let model = AppModel(defaults: AgentTests.defaults())
        defer { withExtendedLifetime(model) {} }
        let box = AgentToolbox(model: model)
        #expect(run(box, "read_page").failed)
        #expect(run(box, "add_block", ["type": "And"]).failed)
        #expect(!run(box, "find_block_types", ["query": "and"]).failed)
    }

    @Test("Results too long for the model are cut, with a note")
    func longResults() {
        let (keep, box) = make(); defer { withExtendedLifetime(keep) {} }
        for i in 0..<320 { _ = run(box, "add_block", ["type": "And", "name": "AndGate\(i)", "x": (i % 10) * 160, "y": (i / 10) * 100]) }
        let page = run(box, "read_page")
        #expect(page.result.count < 26_000)
        #expect(page.result.contains("cut off"))
    }

    // MARK: - The loop

    /// Answers the chat-completions endpoint with `replies` in turn, and keeps the bodies it was sent.
    private func scripted(_ replies: [(Int, [String: Any])], repeating last: Bool = false) {
        StubProtocol.seen = []
        nonisolated(unsafe) var index = 0
        StubProtocol.handler = { _ in
            let (status, body) = replies[min(index, replies.count - 1)]
            index += 1
            return (status, try! JSONSerialization.data(withJSONObject: body))
        }
    }

    private func call(_ name: String, _ args: [String: Any], id: String = "call_1") -> [String: Any] {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return ["choices": [["message": ["role": "assistant", "content": NSNull(),
                                         "tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": json]]]]]]]
    }

    private func text(_ text: String) -> [String: Any] { ["choices": [["message": ["role": "assistant", "content": text]]]] }

    private func agent(for model: AppModel, canEdit: Bool) -> AgentModel {
        let store = InMemorySecretStore()
        _ = store.write("sk-test-key-123", account: "openai")
        let agent = AgentModel(store: store, client: AgentClient(session: StubProtocol.session()), defaults: AgentTests.defaults())
        agent.toolbox = AgentToolbox(model: model)
        agent.canEdit = canEdit
        return agent
    }

    private func finish(_ agent: AgentModel) async {
        for _ in 0..<400 where agent.isSending { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func bodies() -> [[String: Any]] {
        StubProtocol.seen.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    @Test("A model that calls a tool has it run, gets the result back quoting the call's id, and then answers")
    func toolRound() async throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        scripted([(200, call("add_block", ["type": "And", "name": "Gate"])), (200, text("Added an And block."))])
        let agent = agent(for: model, canEdit: true)
        agent.send("add an and gate")
        await finish(agent)

        #expect(agent.error == "")
        #expect(model.project?.modules.contains { $0.name == "Gate" } == true, "the tool really ran")
        let shown = agent.messages.map { "\($0.role.rawValue): \($0.text)" }
        #expect(shown.contains { $0.hasPrefix("tool: Added And") }, "a line says what was done: \(shown)")
        #expect(agent.messages.last?.text == "Added an And block.")

        let sent = bodies()
        #expect(sent.count == 2)
        #expect((sent[0]["tools"] as? [[String: Any]])?.isEmpty == false, "tools are offered")
        let second = try #require(sent[1]["messages"] as? [[String: Any]])
        let assistant = try #require(second.first { ($0["tool_calls"] as? [Any]) != nil })
        #expect(assistant["role"] as? String == "assistant")
        let result = try #require(second.last)
        #expect(result["role"] as? String == "tool")
        #expect(result["tool_call_id"] as? String == "call_1")
        #expect((result["content"] as? String)?.contains("Gate") == true, "the model is told what happened")
        #expect((second.first?["content"] as? String)?.contains("Editing is ON") == true, "the system prompt says whether editing is on")
    }

    @Test("With editing off only reading tools are offered, and a write the model tries anyway is refused and reported")
    func readOnlyLoop() async throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        scripted([(200, call("add_block", ["type": "And"])), (200, text("I can't edit right now."))])
        let agent = agent(for: model, canEdit: false)
        agent.send("add an and gate")
        await finish(agent)

        let offered = (bodies()[0]["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } ?? []
        #expect(offered == AgentToolbox.reading.map(\.name))
        #expect(model.project?.modules.isEmpty == true)
        #expect(agent.messages.contains { $0.role == .tool && $0.failed })
        let second = try #require(bodies()[1]["messages"] as? [[String: Any]])
        #expect((second.first?["content"] as? String)?.contains("Editing is OFF") == true)
    }

    @Test("A model that never stops calling tools is cut off after a fixed number of rounds")
    func roundCap() async {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        scripted([(200, call("project_overview", [:]))])
        let agent = agent(for: model, canEdit: true)
        agent.send("loop")
        await finish(agent)
        #expect(bodies().count == AgentModel.maxRounds)
        #expect(agent.messages.last?.text.contains("stopped after") == true)
        #expect(!agent.isSending && agent.currentAction.isEmpty)
    }

    @Test("A service that rejects tools is asked again without them, and the panel is told")
    func toolsRefused() async {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        scripted([(400, ["error": ["message": "This model does not support tools"]]), (200, text("Plain answer."))])
        let agent = agent(for: model, canEdit: true)
        agent.send("hello")
        await finish(agent)
        #expect(agent.messages.last?.text == "Plain answer.")
        #expect(agent.toolsRefused)
        #expect(agent.toolsRefusal.contains("does not support tools"), "the panel can show what the service said")
        #expect(agent.error == "")
        let sent = bodies()
        #expect(sent.count == 2 && sent[1]["tools"] == nil)
        // The next question does not offer them at all.
        scripted([(200, text("Again."))])
        agent.send("again")
        await finish(agent)
        #expect(bodies().first?["tools"] == nil)
        // A different model is tried with them again.
        agent.model = "another-model"
        #expect(!agent.toolsRefused && agent.toolsRefusal.isEmpty)
        scripted([(200, text("With tools."))])
        agent.send("once more")
        await finish(agent)
        #expect(bodies().first?["tools"] != nil)
    }

    @Test("A model that will not take tools with its default reasoning is asked again with reasoning off, keeps its tools, and remembers")
    func reasoningOffForTools() async throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        // The reply depends on the request: refuse until `reasoning_effort` is "none", then call a tool, then answer.
        StubProtocol.seen = []
        nonisolated(unsafe) var withEffort = 0
        StubProtocol.handler = { @Sendable request in
            let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            if body["reasoning_effort"] as? String != "none" {
                return (400, try! JSONSerialization.data(withJSONObject: ["error": ["message":
                    "Function tools with reasoning_effort are not supported for this-model in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."]]))
            }
            withEffort += 1
            let reply = withEffort == 1
                ? ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "c1", "type": "function",
                    "function": ["name": "add_block", "arguments": "{\"type\":\"And\",\"name\":\"Gate\"}"]]]]]]]
                : ["choices": [["message": ["role": "assistant", "content": "Done."]]]]
            return (200, try! JSONSerialization.data(withJSONObject: reply))
        }
        let agent = agent(for: model, canEdit: true)
        agent.send("add a gate")
        await finish(agent)

        #expect(agent.error == "")
        #expect(!agent.toolsRefused, "the tools were kept, not dropped")
        #expect(model.project?.modules.contains { $0.name == "Gate" } == true, "and used")
        let sent = bodies()
        try #require(sent.count == 3, "refused once, then two rounds with reasoning off (got \(sent.count))")
        #expect(sent[0]["reasoning_effort"] == nil && sent[0]["tools"] != nil)
        #expect(sent[1]["reasoning_effort"] as? String == "none" && sent[1]["tools"] != nil)
        #expect(sent[2]["reasoning_effort"] as? String == "none", "the next round does not ask the refused way first")

        // The next question sends it from the start.
        StubProtocol.seen = []
        withEffort = 1
        agent.send("again")
        await finish(agent)
        #expect(bodies().first?["reasoning_effort"] as? String == "none")
        // A different model is tried the plain way first.
        agent.model = "another-model"
        StubProtocol.seen = []
        agent.send("once more")
        await finish(agent)
        #expect(bodies().first?["reasoning_effort"] == nil)
    }

    @Test("Earlier questions' tool results are dropped from later requests, and the history never starts mid-exchange")
    func historyTrim() async throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        scripted([(200, call("project_overview", [:])), (200, text("Done one.")), (200, text("Done two."))])
        let agent = agent(for: model, canEdit: false)
        agent.send("one")
        await finish(agent)
        agent.send("two")
        await finish(agent)
        let last = try #require(bodies().last?["messages"] as? [[String: Any]])
        let tools = last.filter { $0["role"] as? String == "tool" }
        #expect(tools.count == 1)
        #expect((tools[0]["content"] as? String)?.contains("left out") == true)

        // A long history is cut at a user turn, so no tool answer is left without its call.
        for i in 0..<30 { agent.send("q\(i)"); await finish(agent) }
        let cut = try #require(bodies().last?["messages"] as? [[String: Any]])
        #expect(cut[1]["role"] as? String == "user")
    }

    @Test("A block is configured as what it is, whatever it is called: a renamed ISwitch still has its inputs to set")
    func renamedBlockKeepsItsConfiguration() throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        let box = AgentToolbox(model: model)
        let added = run(box, "add_block", ["type": "ISwitch", "name": "SnakePattern", "x": 40, "y": 40])
        #expect(!added.failed, "\(added.result)")
        let module = try #require(model.project?.modules.first { $0.name == "SnakePattern" })
        #expect(BlockConfigKind(module) == .switchInputs)
        let configured = run(box, "configure_block", ["block": module.id, "values": ["inputs": 6]])
        #expect(!configured.failed, "\(configured.result)")
        #expect(model.project?.modules.first { $0.id == module.id }?.inPins.count == 8, "En, Sw and six X inputs")
    }

    @Test("A long task keeps its question: however many steps it takes, every request still carries it")
    func longTaskKeepsItsQuestion() async throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        // Thirty steps, each a call and its answer: far more than the history cap, which once cut the question out of the request
        // and, with no user turn left, sent the service nothing but the system prompt.
        scripted(Array(repeating: (200, call("project_overview", [:])), count: 30) + [(200, text("Done."))])
        let agent = agent(for: model, canEdit: false)
        agent.send("build a snake that circles a segment")
        await finish(agent)
        let all = bodies()
        #expect(all.count == 31)
        for (round, body) in all.enumerated() {
            let sent = try #require(body["messages"] as? [[String: Any]])
            let users = sent.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
            #expect(users == ["build a snake that circles a segment"], "round \(round) lost the question: \(users)")
        }
        #expect(agent.messages.last?.text == "Done.")
    }

    @Test("Clearing the conversation clears what goes to the service too")
    func clearing() async throws {
        let (model, keep) = make(); defer { withExtendedLifetime(keep) {} }
        scripted([(200, text("hi")), (200, text("again"))])
        let agent = agent(for: model, canEdit: false)
        agent.send("first")
        await finish(agent)
        agent.clear()
        agent.send("second")
        await finish(agent)
        let sent = try #require(bodies().last?["messages"] as? [[String: Any]])
        #expect(sent.count == 2, "only the system prompt and the new question")
    }

    @Test("The editing switch is remembered, and off by default")
    func switchPersists() {
        let defaults = AgentTests.defaults()
        let a = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: defaults)
        #expect(!a.canEdit)
        a.canEdit = true
        let b = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: defaults)
        #expect(b.canEdit)
    }
}
}
#endif
