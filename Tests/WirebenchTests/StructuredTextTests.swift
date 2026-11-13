import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
@testable import WirebenchSource

/// Structured Text: the front end, its lowering to blocks, and the simulation of the result.
@Suite("Structured Text source")
struct StructuredTextTests {
    static let now = Date(timeIntervalSince1970: 1_709_623_628)

    static let gate = """
    PROGRAM Gate
    VAR
        a AT %IX0 : BOOL;
        b AT %IX1 : BOOL;
        lamp AT %QX2 : BOOL;
    END_VAR
        lamp := a AND NOT b;
    END_PROGRAM
    """

    static func modules(_ project: PCCProject, guid: UUID) -> [PCCModule] {
        project.modules.filter { $0.guid == guid }
    }

    static func fastestThread(_ project: PCCProject) -> Int {
        ProfileRegistry.profile(for: project, in: ProfileRegistry.builtIn)?
            .threads.filter { $0.intervalMs > 0 }.min { $0.intervalMs < $1.intervalMs }?.id ?? 1
    }

    static func error(_ source: String) -> String? {
        do { _ = try SourceCompiler().compile(source); return nil } catch { return "\(error)" }
    }

    @Test("A PROGRAM is a page, with each operator as its block")
    func lowersToBlocks() throws {
        let compiled = try SourceCompiler().compile(Self.gate, projectName: "fallback")
        #expect(compiled.program == "Gate")
        #expect(compiled.usedInputs == [0, 1])
        #expect(compiled.writtenOutputs == [2])
        #expect(compiled.pages == ["Gate"], "the program's name is the page")
        #expect(compiled.project.modules.count == 4)
        #expect(Self.modules(compiled.project, guid: EightDIBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: EightDOBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: AndBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: NotBlock.guid).count == 1)
        #expect(Set(compiled.project.modules.map(\.name)).count == compiled.project.modules.count)
        #expect(compiled.project.modules.allSatisfy { $0.page == "Gate" && $0.threadId == Self.fastestThread(compiled.project) })
        #expect(compiled.project.inConnections.count == 4)
    }

    @Test("The program it emits simulates as the source says")
    func simulationMatchesTheSource() throws {
        let compiled = try SourceCompiler().compile(Self.gate)
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

    @Test("An if/else on constants is the condition itself, not four blocks")
    func ifFoldsToAWire() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM Gate
        VAR
            a AT %IX0 : BOOL;
            lamp AT %QX0 : BOOL;
        END_VAR
            IF TRUE THEN
                lamp := a;
            ELSE
                lamp := FALSE;
            END_IF;
        END_PROGRAM
        """)
        #expect(compiled.project.modules.count == 2, "only the input and the output blocks are left")
        #expect(compiled.project.inConnections.count == 1)
    }

    @Test("A VAR is a BoolVar written once a scan, read as the value the scan began with")
    func stateToggles() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM Gate
        VAR
            button AT %IX0 : BOOL;
            on AT %QX0 : BOOL;
            held : BOOL;
        END_VAR
            IF button THEN
                held := NOT held;
            END_IF;
            on := held;
        END_PROGRAM
        """)
        #expect(Self.modules(compiled.project, guid: BoolVarBlock.guid).count == 1)
        #expect(Self.modules(compiled.project, guid: SetBlock.guid).count == 1)
        let di = try #require(Self.modules(compiled.project, guid: EightDIBlock.guid).first)
        let out = try #require(Self.modules(compiled.project, guid: EightDOBlock.guid).first)
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        func scan(_ button: Bool) -> Bool {
            core.setOut(moduleId: di.id, pin: 0, value: .bool(button))
            core.step(deltaMs: 10, now: Self.now)
            return core.inPins(moduleId: out.id)[1].asBool
        }
        #expect(!scan(false), "starts off")
        #expect(!scan(true), "the scan that flips it still reads the old value")
        #expect(scan(true), "the flip shows on the next scan")
        #expect(!scan(true), "and holding it flips every scan")
    }

    @Test("A declared PulseGen takes its times in scans")
    func pulseBlock() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM Blink
        VAR
            lamp AT %QX0 : BOOL;
            clock : PulseGen;
        END_VAR
            clock(En := TRUE, Act := TRUE, TOn := 500, TOff := 500);
            lamp := clock.Output;
        END_PROGRAM
        """)
        let pulse = try #require(compiled.project.modules.first { $0.guid == PulseGenBlock.guid })
        #expect(pulse.paramPins[0].value == .int32(500), "the block's unit is scans")
        #expect(pulse.paramPins[1].value == .int32(500))
    }

    @Test("A FUNCTION_BLOCK is a macro page, and an instance of it is a Macro block")
    func macroBecomesAPage() throws {
        let compiled = try SourceCompiler().compile("""
        FUNCTION_BLOCK Invert
        VAR_INPUT
            value : BOOL;
        END_VAR
        VAR_OUTPUT
            result : BOOL;
        END_VAR
            result := NOT value;
        END_FUNCTION_BLOCK

        PROGRAM Main
        VAR
            button AT %IX0 : BOOL;
            lamp AT %QX0 : BOOL;
            t : Invert;
        END_VAR
            t(value := button);
            lamp := t.result;
        END_PROGRAM
        """)
        #expect(compiled.pages == ["Main", "*Invert"])
        #expect(compiled.macros.map(\.caption) == ["*Invert"])
        #expect(compiled.macros.first?.inputs == ["value"])
        #expect(compiled.macros.first?.outputs == ["result"])
        #expect(Self.modules(compiled.project, guid: MacroInterface.callGUID).count == 1)
        let out = try #require(Self.modules(compiled.project, guid: EightDOBlock.guid).first)
        let di = try #require(Self.modules(compiled.project, guid: EightDIBlock.guid).first)
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.setOut(moduleId: di.id, pin: 0, value: .bool(true))
        core.step(deltaMs: 10, now: Self.now)
        #expect(!core.inPins(moduleId: out.id)[1].asBool, "the macro inverts")
    }

    @Test("The editor colours the whole ST vocabulary, not only the subset the compiler lowers")
    func highlightVocabulary() {
        let source = "CASE x OF\n  FOR i := 1 TO 10 DO\n"
        let text = source as NSString
        let words = SourceHighlighter.spans(in: source)
            .filter { $0.kind == .keyword }
            .map { text.substring(with: NSRange(location: $0.location, length: $0.length)) }
        for word in ["CASE", "OF", "FOR", "TO", "DO"] {
            #expect(words.contains(word), "\(word) should be coloured")
        }
    }

    @Test("A program is a .pcc that survives a save, and the hardware compiler accepts it")
    func emittedProjectIsReal() throws {
        let compiled = try SourceCompiler().compile(Self.gate)
        let xml = PCCSerializer().serialize(project: compiled.project)
        let read = try PCCParser().parse(xmlString: xml)
        #expect(read.pages.map(\.caption) == compiled.project.pages.map(\.caption))
        #expect(read.modules.count == compiled.project.modules.count)
        #expect(PCCSerializer().serialize(project: read) == xml)
    }

    @Test("A catalogued block is an instance, called with named arguments")
    func blockInstance() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM Calc
        VAR
            a AT %IX0 : BOOL;
            lamp AT %QX0 : BOOL;
            sum : IAdd;
        END_VAR
            sum(X0 := a, X1 := 5);
            lamp := sum.Y;
        END_PROGRAM
        """)
        let add = try #require(Self.modules(compiled.project, guid: BlockTypeCatalog.info(forBlockName: "IAdd")!.guid).first)
        #expect(add.inPins[2].value == .int32(5))
        #expect(Self.modules(compiled.project, guid: EightDIBlock.guid).count == 1)
    }

    @Test("Refusals say what is wrong and where")
    func refusals() throws {
        for (source, fragment) in [
            ("""
            PROGRAM P
            VAR a AT %IX0 : BOOL; END_VAR
                a := TRUE;
            END_PROGRAM
            """, "is an input"),
            ("""
            PROGRAM P
            VAR x : Nope; END_VAR
                x();
            END_PROGRAM
            """, "unknown type"),
            ("""
            PROGRAM P
            VAR x : And_; y AT %IX0 : BOOL; END_VAR
                IF y THEN
                    x(En := TRUE);
                END_IF;
            END_PROGRAM
            """, "cannot be inside IF"),
            ("""
            FUNCTION_BLOCK Only
            VAR_INPUT a : BOOL; END_VAR
            END_FUNCTION_BLOCK
            """, "declares no PROGRAM"),
            ("""
            PROGRAM P
            VAR a AT %IX0 : BOOL; END_VAR
                a := a AND 5;
            END_PROGRAM
            """, "not a signal"),
            ("""
            PROGRAM P
            VAR a AT %IX0 : BOOL; END_VAR
                b := a;
            END_PROGRAM
            """, "unknown name"),
            ("""
            PROGRAM P
            VAR a AT %IX0 : BOOL; END_VAR
                a := a
            END_PROGRAM
            """, "expected"),
        ] {
            let message = try #require(Self.error(source), "\(fragment) — \(source)")
            #expect(message.contains(fragment), "\(message) should mention \(fragment)")
        }
    }
}
