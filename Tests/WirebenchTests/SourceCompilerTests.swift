import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
import WirebenchHardware
import WirebenchModel
@testable import WirebenchSource

/// PLC Swift: the subset front end and its lowering to blocks and pages.
///
/// The compiler's job is a dataflow graph that behaves like the source. These check the graph it builds, simulate it with the
/// same core the app uses, and prove the result is a `.pcc` the hardware compiler accepts.
@Suite("PLC Swift source")
struct SourceCompilerTests {
    static let now = Date(timeIntervalSince1970: 1_709_623_628)

    static let gate = """
    @main
    struct Gate {
        @DI(0) var a: Bool
        @DI(1) var b: Bool
        @DO(2) var lamp: Bool

        func scan() {
            let both = a && !b
            lamp = both
        }
    }
    """

    static func modules(_ project: PCCProject, guid: UUID) -> [PCCModule] {
        project.modules.filter { $0.guid == guid }
    }

    static func fastestThread(_ project: PCCProject) -> Int {
        ProfileRegistry.profile(for: project, in: ProfileRegistry.builtIn)?
            .threads.filter { $0.intervalMs > 0 }.min { $0.intervalMs < $1.intervalMs }?.id ?? 1
    }

    @Test("A struct is a page, with each operator as its block")
    func lowersToBlocks() throws {
        let compiled = try SwiftSourceCompiler().compile(Self.gate, projectName: "fallback")
        #expect(compiled.entryPoint == "scan")
        #expect(compiled.usedInputs == [0, 1])
        #expect(compiled.writtenOutputs == [2])
        #expect(compiled.pages == ["Gate"], "the struct's name is the page")
        #expect(compiled.project.modules.count == 4)
        #expect(Self.modules(compiled.project, guid: EightDIBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: EightDOBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: AndBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: NotBlock.guid).count == 1)
        #expect(Set(compiled.project.modules.map(\.name)).count == compiled.project.modules.count, "block names repeat")
        #expect(compiled.project.modules.allSatisfy { $0.page == "Gate"
            && $0.threadId == Self.fastestThread(compiled.project) })
        #expect(compiled.project.inConnections.count == 4)
    }

    @Test("The program it emits simulates as the source says")
    func simulationMatchesTheSource() throws {
        let compiled = try SwiftSourceCompiler().compile(Self.gate)
        let project = compiled.project
        let di = try #require(Self.modules(project, guid: EightDIBlock.guid).first)
        let out = try #require(Self.modules(project, guid: EightDOBlock.guid).first)
        let core = CxxSimulationCore(project: project, profileScheduling: false)

        func run(_ inputs: (Int, Bool)...) -> Bool {
            for (pin, value) in inputs { core.setOut(moduleId: di.id, pin: pin, value: .bool(value)) }
            core.step(deltaMs: 10, now: Self.now)
            return core.inPins(moduleId: out.id)[3].asBool
        }
        #expect(run((0, true), (1, false)))
        #expect(!run((0, true), (1, true)))
        #expect(!run((0, false), (1, false)))
    }

    @Test("An assignment's right side can be a whole expression")
    func assignmentWithExpression() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        struct Gate {
            @DI(0) var a: Bool
            @DI(1) var b: Bool
            @DO(2) var lamp: Bool
            func scan() { lamp = a && !b }
        }
        """)
        #expect(compiled.writtenOutputs == [2])
        let di = try #require(Self.modules(compiled.project, guid: EightDIBlock.guid).first)
        let out = try #require(Self.modules(compiled.project, guid: EightDOBlock.guid).first)
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        func run(_ a: Bool, _ b: Bool) -> Bool {
            core.setOut(moduleId: di.id, pin: 0, value: .bool(a))
            core.setOut(moduleId: di.id, pin: 1, value: .bool(b))
            core.step(deltaMs: 10, now: Self.now)
            return core.inPins(moduleId: out.id)[3].asBool
        }
        #expect(run(true, false))
        #expect(!run(true, true))
        #expect(!run(false, false))
    }

    @Test("An if/else on constants is the condition itself, not four blocks")
    func ifFoldsToAWire() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        struct Gate {
            @DI(0) var start: Bool
            @DO(1) var lamp: Bool
            func scan() {
                if start { lamp = true } else { lamp = false }
            }
        }
        """)
        #expect(compiled.project.modules.count == 2, "only the 8xDI and the 8xDO are needed")
        let connection = try #require(compiled.project.inConnections.first)
        #expect(connection.inPinId == 2, "DO1 is input 2 of the 8xDO")
        #expect(connection.outPinId == 0)
    }

    @Test("A stored property is a BoolVar written once a scan, and read as the value the scan began with")
    func stateToggles() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        struct Lamp {
            @DI(0) var button: Bool
            @DO(1) var lamp: Bool
            var on: Bool = false

            func scan() {
                if button { on = !on }
                lamp = on
            }
        }
        """)
        #expect(compiled.variables == ["on"])
        #expect(Self.modules(compiled.project, guid: BoolVarBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: SetBlock.guid).count == 1)

        let project = compiled.project
        let di = try #require(Self.modules(project, guid: EightDIBlock.guid).first)
        let out = try #require(Self.modules(project, guid: EightDOBlock.guid).first)
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        func scan(button: Bool) -> Bool {
            core.setOut(moduleId: di.id, pin: 0, value: .bool(button))
            core.step(deltaMs: 10, now: Self.now)
            return core.inPins(moduleId: out.id)[2].asBool
        }
        #expect(!scan(button: true))    // on becomes true at the end of this scan
        #expect(scan(button: false))    // on is true, and stays true
        #expect(scan(button: true))     // on becomes false at the end
        #expect(!scan(button: false))   // on is false and stays false
    }

    @Test("pulse(ms:) is a PulseGen whose times are the milliseconds split by the thread's period")
    func pulseConvertsToCycles() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        struct Blink {
            @DO(0) var lamp: Bool
            func scan() { lamp = pulse(ms: 1000) }
        }
        """)
        let pulse = try #require(Self.modules(compiled.project, guid: PulseGenBlock.guid).first)
        let interval = try #require(ProfileRegistry.profile(for: compiled.project, in: ProfileRegistry.builtIn)?
            .threads.filter { $0.intervalMs > 0 }.min { $0.intervalMs < $1.intervalMs }?.intervalMs)
        let on = pulse.paramPins[0].value.asInt
        let off = pulse.paramPins[1].value.asInt
        #expect(on + off == max(2, Int((1000.0 / Double(interval)).rounded())))
        #expect(pulse.inPins[1].value.asBool, "the PulseGen has to be active")
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        var seen = Set<Bool>()
        for _ in 0..<(on + off + 2) {
            core.step(deltaMs: 10, now: Self.now)
            seen.insert(core.outPins(moduleId: pulse.id)[1].asBool)
        }
        #expect(seen.count == 2, "the pulse never changed state")
    }

    @Test("A macro is a page: its @Input/@Output are the interface, and a call is a Macro block")
    func macroBecomesAPage() throws {
        let source = """
        @main
        struct Main {
            @DI(0) var button: Bool
            @DO(1) var lamp: Bool

            func scan() {
                let t = Toggle(value: button)
                lamp = t.result
            }
        }

        @macro
        struct Toggle {
            @Input(0) var value: Bool
            @Output(0) var result: Bool

            func scan() {
                result = !value
            }
        }
        """
        let compiled = try SwiftSourceCompiler().compile(source)
        #expect(compiled.pages == ["Main", "*Toggle"])
        #expect(compiled.macros == [CompiledMacro(name: "Toggle", caption: "*Toggle",
                                                  inputs: ["value"], outputs: ["result"])])

        let call = try #require(Self.modules(compiled.project, guid: MacroInterface.callGUID).first)
        #expect(call.page == "Main")
        #expect(call.rawAttributes["MACRO_NAME"] == "Toggle")
        #expect(call.inPins.map(\.name) == ["value"])
        #expect(call.outPins.map(\.name) == ["result"])

        let inputs = try #require(Self.modules(compiled.project, guid: MacroInterface.interfaceGUID)
            .first { $0.rawAttributes["MACRO_NAME"] == "Inputs" })
        #expect(inputs.page == "*Toggle")
        #expect(inputs.outPins.map(\.name) == ["value"])
        #expect(inputs.threadId == 0, "macro pages are stored on thread 0")

        let outputs = try #require(Self.modules(compiled.project, guid: MacroInterface.interfaceGUID)
            .first { $0.rawAttributes["MACRO_NAME"] == "Outputs" })
        #expect(outputs.inPins.map(\.name) == ["result"])
        // The call's input is wired from the button, its output to the lamp.
        #expect(compiled.project.inConnections.contains { $0.inModuleId == call.id && $0.inPinId == 0 })
        #expect(compiled.project.inConnections.contains { $0.outModuleId == call.id && $0.outPinId == 0 })
    }

    @Test("A macro call runs: the compiled project inverts the input through it")
    func macroSimulates() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        @main
        struct Main {
            @DI(0) var button: Bool
            @DO(1) var lamp: Bool
            func scan() {
                let t = Toggle(value: button)
                lamp = t.result
            }
        }

        @macro
        struct Toggle {
            @Input(0) var value: Bool
            @Output(0) var result: Bool
            func scan() { result = !value }
        }
        """)
        let project = compiled.project
        let di = try #require(Self.modules(project, guid: EightDIBlock.guid).first)
        let out = try #require(Self.modules(project, guid: EightDOBlock.guid).first)
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        func run(_ input: Bool) -> Bool {
            core.setOut(moduleId: di.id, pin: 0, value: .bool(input))
            core.step(deltaMs: 10, now: Self.now)
            return core.inPins(moduleId: out.id)[2].asBool
        }
        #expect(run(true) == false)
        #expect(run(false) == true)
    }

    @Test("The emitted project is a .pcc that survives a save, and the hardware compiler accepts it")
    func emittedProjectIsReal() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        @main
        struct Main {
            @DI(0) var button: Bool
            @DO(1) var lamp: Bool
            func scan() { lamp = !button }
        }
        """)
        let once = PCCSerializer().serialize(project: compiled.project)
        let parsed = try PCCParser().parse(xmlString: once)
        #expect(PCCSerializer().serialize(project: parsed) == once)

        let template = try PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640))
        let build = try PLCProjectBuild.compile(xml: once, classForGUID: BlockTypeCatalog.classNamesByGUID, template: template)
        #expect(build.report.isComplete, "the compiler left something out: \(build.report.lines)")
        #expect(!build.table.isEmpty)
    }

    @Test("The parser reads an import and takes the main struct's name")
    func parsesImports() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        import PLC
        @main
        struct Lamp {
            @DO(0) var lamp: Bool
            func scan() { lamp = true }
        }
        """, projectName: "fallback")
        #expect(compiled.project.name == "Lamp")
    }

    @Test("What the subset does not have is refused, with a line")
    func refusesTheRest() {
        func error(_ source: String) -> String? {
            do { _ = try SwiftSourceCompiler().compile(source); return nil }
            catch { return "\(error)" }
        }
        #expect(error("""
        struct P { @DO(9) var x: Bool
        func scan() { x = true } }
        """)?.contains("does not exist") == true)
        #expect(error("""
        struct P { @DO(0) var x: Bool
        func scan() { x = missing } }
        """)?.contains("unknown name 'missing'") == true)
        #expect(error("""
        struct P { @DO(0) var x: Bool
        func scan() { x = 5 } }
        """)?.contains("not a signal") == true)
        #expect(error("""
        struct P { @DI(0) var i: Bool
        func scan() { i = true } }
        """)?.contains("input") == true)
        #expect(error("""
        struct P { @DI(0) var a: Bool
        @DI(0) var b: Bool
        func scan() { } }
        """)?.contains("declared twice") == true)
        #expect(error("""
        struct P { @DO(0) var x: Bool
        func scan() { var y = x
        x = y } }
        """)?.contains("var") == true)
        #expect(error("""
        struct P { @DO(0) var x: Bool
        func scan() { x = pulse(ms: 0) } }
        """)?.contains("above zero") == true)
        #expect(error("""
        struct P { @DO(0) var x: Bool
        func scan() { x = pulse(ms: 1) } }
        """)?.contains("shorter than") == true)
        #expect(error("""
        struct P { @Input(0) var a: Bool
        func scan() { } }
        """)?.contains("belongs in a macro") == true)
        #expect(error("""
        @macro struct M { @Input(0) var a: Bool
        @Output(0) var y: Bool
        func scan() { y = a } }
        struct P { func scan() {
            let t = M(a: true)
            let u = t.nope
        } }
        """)?.contains("no output 'nope'") == true)
        #expect(error("""
        @macro struct M { @Input(0) var a: Bool
        func scan() { } }
        struct P { func scan() {
            let t = M(a: true)
            if true { let u = M(a: false) }
        } }
        """)?.contains("inside 'if'") == true)
        #expect(error("""
        struct P { @DO(0) var x: Bool
        func scan() { x = true } }
        """) == nil, "a page that drives its pin is valid")
    }
}

/// The editor's colours come from the same parse, so they are checked against the offsets `NSTextStorage` uses.
@Suite("PLC Swift highlighting")
struct SourceHighlighterTests {
    @Test("Keywords, comments, attributes, declarations and types are coloured")
    func highlights() throws {
        let source = "// lamp\n@DI(0) var button: Bool"
        let spans = SwiftSourceHighlighter.spans(in: source)
        func kinds(_ text: String) -> [SyntaxTokenKind] {
            let ns = source as NSString
            let range = ns.range(of: text)
            return spans.filter { $0.location == range.location && $0.length == range.length }.map(\.kind)
        }
        #expect(kinds("// lamp").contains(.comment))
        #expect(kinds("DI").contains(.attribute))
        #expect(kinds("button").contains(.declaration))
        #expect(kinds("Bool").contains(.type))
    }

    @Test("Spans stay aligned past characters with more UTF-8 bytes than UTF-16 units")
    func offsetsPastAccentedText() throws {
        let source = "// žluťoučký kůň\nlet lamp = true"
        let spans = SwiftSourceHighlighter.spans(in: source)
        let ns = source as NSString
        let keyword = ns.range(of: "let")
        let literal = ns.range(of: "true")
        #expect(spans.contains { $0.location == keyword.location && $0.kind == .keyword })
        #expect(spans.contains { $0.location == literal.location && $0.kind == .keyword })
        #expect(spans.allSatisfy { $0.location >= 0 && $0.location + $0.length <= ns.length })
    }

    @Test("An adopted project becomes the open document")
    @MainActor
    func adoptsCompiledProject() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        struct Gate {
            @DI(0) var a: Bool
            @DO(2) var lamp: Bool
            func scan() { lamp = a }
        }
        """, projectName: "Gate")
        let model = AppModel()
        model.adoptCompiledProject(compiled.project)
        #expect(model.project?.modules.count == compiled.blockCount)
        #expect(model.project?.name == "Gate")
        #expect(model.currentFileURL == nil)
        #expect(model.selectedPage == "Gate")
    }
}
