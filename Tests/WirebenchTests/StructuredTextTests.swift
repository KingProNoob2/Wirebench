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

    @Test("Typed declarations parse: INT, LONG and REAL with typed initialisers")
    func typedDeclarations() throws {
        let program = try SourceParser.parse("""
        PROGRAM P
        VAR
            n : INT := 5;
            l : LONG := -2;
            r : REAL := 1.5;
            b : BOOL := TRUE;
        END_VAR
        END_PROGRAM
        """)
        let unit = try #require(program.main)
        #expect(unit.variables.map(\.type) == [.int, .long, .real, .bool])
        #expect(unit.variables[0].initial == .integer(5))
        #expect(unit.variables[1].initial == .integer(-2))
        #expect(unit.variables[2].initial == .real(1.5))
        #expect(unit.variables[3].initial == .boolean(true))
    }

    @Test("An INT variable counts with IAdd, and a comparison drives a BOOL output")
    func typedArithmetic() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            lamp AT %QX0 : BOOL;
            n : INT := 0;
        END_VAR
            n := n + 1;
            lamp := n > 3;
        END_PROGRAM
        """)
        let guid: (String) -> UUID? = { BlockTypeCatalog.info(forBlockName: $0)?.guid }
        #expect(compiled.project.modules.contains { $0.guid == guid("IntVar") })
        #expect(compiled.project.modules.contains { $0.guid == guid("IAdd") })
        #expect(compiled.project.modules.contains { $0.guid == guid("Comparator") })

        let out = try #require(compiled.project.modules.first { $0.guid == EightDOBlock.guid })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        var values: [Bool] = []
        for _ in 0..<5 {
            core.step(deltaMs: 10, now: Self.now)
            values.append(core.inPins(moduleId: out.id)[1].asBool)
        }
        #expect(values == [false, false, false, false, true], "n > 3 is true on the fifth scan: \(values)")
    }

    @Test("A REAL variable uses FloatVar and FAdd")
    func realArithmetic() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            r : REAL := 1.5;
        END_VAR
            r := r + 0.5;
        END_PROGRAM
        """)
        let guid: (String) -> UUID? = { BlockTypeCatalog.info(forBlockName: $0)?.guid }
        #expect(compiled.project.modules.contains { $0.guid == guid("FloatVar") })
        #expect(compiled.project.modules.contains { $0.guid == guid("FAdd") })
        #expect(compiled.project.modules.contains { $0.guid == SetBlock.guid })
    }

    @Test("An if/else on a numeric variable becomes a typed selection and simulates")
    func numericIf() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            button AT %IX0 : BOOL;
            n : INT := 0;
        END_VAR
            IF button THEN
                n := n + 1;
            ELSE
                n := n + 2;
            END_IF;
        END_PROGRAM
        """)
        let guid: (String) -> UUID? = { BlockTypeCatalog.info(forBlockName: $0)?.guid }
        #expect(compiled.project.modules.contains { $0.guid == guid("ISwitch") })
        let variable = try #require(compiled.project.modules.first { $0.guid == guid("IntVar") })
        let di = try #require(compiled.project.modules.first { $0.guid == EightDIBlock.guid })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.setOut(moduleId: di.id, pin: 0, value: .bool(false))
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 2, "the ELSE branch runs when button is 0")
    }

    @Test("A LONG variable adds through LAdd and the value reaches its output")
    func longArithmetic() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            l : LONG := 1;
        END_VAR
            l := l + 2;
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "LongVar")?.guid
        })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 3)
    }

    @Test("A REAL variable adds through FAdd and the value reaches its output")
    func realSimulation() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            r : REAL := 1.5;
        END_VAR
            r := r + 0.5;
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "FloatVar")?.guid
        })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(abs(core.outPins(moduleId: variable.id)[0].asFloat - 2.0) < 0.001)
    }

    @Test("Typed refusals: narrowing, REAL comparison and a missing arithmetic block")
    func typedRefusals() {
        let cases: [(String, String)] = [
            ("""
             PROGRAM P
             VAR n : INT := 1; END_VAR
                 n := 1.5;
             END_PROGRAM
             """, "narrowed"),
            ("""
             PROGRAM P
             VAR r : REAL := 1.5; b AT %QX0 : BOOL; END_VAR
                 b := r > 1.0;
             END_PROGRAM
             """, "REAL comparison"),
            ("""
             PROGRAM P
             VAR l : LONG := 1; END_VAR
                 l := l * 2;
             END_PROGRAM
             """, "no block computes"),
        ]
        for (source, fragment) in cases {
            let message = Self.error(source)
            #expect(message?.contains(fragment) == true, "\(fragment): \(message ?? "compiled")")
        }
    }

    @Test("CASE selects an arm and simulates through comparisons")
    func caseStatement() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            lamp AT %QX0 : BOOL;
            n : INT := 2;
        END_VAR
            CASE n OF
                0: lamp := FALSE;
                1, 2: lamp := TRUE;
                5..7: lamp := FALSE;
            ELSE
                lamp := FALSE;
            END_CASE;
        END_PROGRAM
        """)
        let out = try #require(compiled.project.modules.first { $0.guid == EightDOBlock.guid })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.inPins(moduleId: out.id)[1].asBool)
    }

    @Test("CASE handles a negative range")
    func caseRange() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            lamp AT %QX0 : BOOL;
            n : INT := -1;
        END_VAR
            CASE n OF
                -1..1: lamp := TRUE;
            ELSE
                lamp := FALSE;
            END_CASE;
        END_PROGRAM
        """)
        let out = try #require(compiled.project.modules.first { $0.guid == EightDOBlock.guid })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.inPins(moduleId: out.id)[1].asBool)
    }

    @Test("CASE refusals: overlapping labels, a REAL selector, a missing END_CASE")
    func caseRefusals() {
        let cases: [(String, String)] = [
            ("""
             PROGRAM P
             VAR n : INT := 1; END_VAR
                 CASE n OF
                     1: n := 1;
                     1: n := 2;
                 END_CASE;
             END_PROGRAM
             """, "overlap"),
            ("""
             PROGRAM P
             VAR r : REAL := 1.0; b AT %QX0 : BOOL; END_VAR
                 CASE r OF
                     1: b := TRUE;
                 END_CASE;
             END_PROGRAM
             """, "REAL comparison"),
            ("""
             PROGRAM P
             VAR n : INT := 1; END_VAR
                 CASE n OF
                     1: n := 2;
             END_PROGRAM
             """, "expected END_CASE"),
        ]
        for (source, fragment) in cases {
            let message = Self.error(source)
            #expect(message?.contains(fragment) == true, "\(fragment): \(message ?? "compiled")")
        }
    }

    @Test("FOR unrolls constant bounds and counts sequentially")
    func forCounts() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            n : INT := 0;
        END_VAR
            FOR i := 1 TO 3 DO
                n := n + 1;
            END_FOR;
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "IntVar")?.guid
        })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 3)
    }

    @Test("FOR substitutes the index into each unrolled body")
    func forIndex() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            n : INT := 0;
            i : INT;
        END_VAR
            FOR i := 1 TO 3 DO
                n := n + i;
            END_FOR;
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "IntVar")?.guid
        })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 6, "0 + 1 + 2 + 3")
    }

    @Test("FOR goes downwards with a negative BY")
    func forNegativeStep() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            n : INT := 0;
        END_VAR
            FOR i := 3 TO 1 BY -1 DO
                n := n + 1;
            END_FOR;
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "IntVar")?.guid
        })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 3)
    }

    @Test("Loop refusals: a live bound, a zero step, an index write, the cap, WHILE and REPEAT")
    func loopRefusals() {
        let cases: [(String, String)] = [
            ("""
             PROGRAM P
             VAR n : INT := 2; END_VAR
                 FOR i := 1 TO n DO
                     n := n + 1;
                 END_FOR;
             END_PROGRAM
             """, "FOR bound"),
            ("""
             PROGRAM P
             VAR n : INT := 0; END_VAR
                 FOR i := 1 TO 3 BY 0 DO
                     n := n + 1;
                 END_FOR;
             END_PROGRAM
             """, "step cannot be zero"),
            ("""
             PROGRAM P
             VAR n : INT := 0; END_VAR
                 FOR i := 1 TO 3 DO
                     i := i + 1;
                 END_FOR;
             END_PROGRAM
             """, "index cannot be assigned"),
            ("""
             PROGRAM P
             VAR n : INT := 0; END_VAR
                 FOR i := 1 TO 1000 DO
                     n := n + 1;
                 END_FOR;
             END_PROGRAM
             """, "256"),
            ("""
             PROGRAM P
             VAR n : INT := 0; END_VAR
                 WHILE n < 3 DO
                     n := n + 1;
                 END_WHILE;
             END_PROGRAM
             """, "WHILE is not supported"),
            ("""
             PROGRAM P
             VAR n : INT := 0; END_VAR
                 REPEAT
                     n := n + 1;
                 UNTIL n = 3
                 END_REPEAT;
             END_PROGRAM
             """, "REPEAT is not supported"),
        ]
        for (source, fragment) in cases {
            let message = Self.error(source)
            #expect(message?.contains(fragment) == true, "\(fragment): \(message ?? "compiled")")
        }
    }

    @Test("An INT array writes and reads through the data area")
    func arrayReadWrite() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            a : ARRAY[0..3] OF INT;
            n : INT := 0;
        END_VAR
            a[1] := 42;
            n := a[1] + 1;
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "IntVar")?.guid
        })
        #expect(compiled.project.modules.contains { $0.guid == BlockTypeCatalog.info(forBlockName: "CreateIntArray")?.guid })
        #expect(compiled.project.modules.contains { $0.guid == BlockTypeCatalog.info(forBlockName: "ReadIntArray")?.guid })
        #expect(compiled.project.modules.contains { $0.guid == BlockTypeCatalog.info(forBlockName: "WriteIntArray")?.guid })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)   // writes 42; the read earlier in the scan saw 0
        core.step(deltaMs: 10, now: Self.now)   // now reads 42
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 43)
    }

    @Test("An array's declared lower bound is honoured")
    func arrayLowerBound() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            a : ARRAY[5..7] OF INT;
            n : INT := 0;
        END_VAR
            a[5] := 7;
            n := a[5];
        END_PROGRAM
        """)
        let variable = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "IntVar")?.guid
        })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Self.now)
        core.step(deltaMs: 10, now: Self.now)
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 7)
    }

    @Test("Array refusals: REAL elements, a reversed range, a REAL index, a write in IF, a bare name")
    func arrayRefusals() {
        let cases: [(String, String)] = [
            ("""
             PROGRAM P
             VAR a : ARRAY[0..3] OF REAL; END_VAR
             END_PROGRAM
             """, "only INT and LONG arrays"),
            ("""
             PROGRAM P
             VAR a : ARRAY[3..1] OF INT; END_VAR
             END_PROGRAM
             """, "count upwards"),
            ("""
             PROGRAM P
             VAR a : ARRAY[0..3] OF INT; n : INT := 0; END_VAR
                 n := a[1.5];
             END_PROGRAM
             """, "integer, not REAL"),
            ("""
             PROGRAM P
             VAR a : ARRAY[0..3] OF INT; b AT %IX0 : BOOL; END_VAR
                 IF b THEN
                     a[1] := 2;
                 END_IF;
             END_PROGRAM
             """, "cannot be inside IF"),
            ("""
             PROGRAM P
             VAR a : ARRAY[0..3] OF INT; n : INT := 0; END_VAR
                 n := a;
             END_PROGRAM
             """, "read an element"),
        ]
        for (source, fragment) in cases {
            let message = Self.error(source)
            #expect(message?.contains(fragment) == true, "\(fragment): \(message ?? "compiled")")
        }
    }

    @Test("Completion offers keywords, block types, instance names and an instance's outputs")
    func completion() {
        let source = """
        PROGRAM P
        VAR
            a AT %IX0 : BOOL;
            lamp AT %QX0 : BOOL;
            sum : IAdd;
        END_VAR
            sum(X0 := a, X1 := 5);
            lamp := sum.Y;
        END_PROGRAM
        """
        #expect(SourceCompletion.suggestions(in: source, partial: "su", beforeCaret: "    ").contains("sum"))
        #expect(SourceCompletion.suggestions(in: source, partial: "", beforeCaret: "    sum.").contains("Y"))
        #expect(SourceCompletion.suggestions(in: source, partial: "IA", beforeCaret: "").contains("IAdd"))
        #expect(SourceCompletion.suggestions(in: source, partial: "TH", beforeCaret: "").contains("THEN"))
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
            """, "BOOL"),
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
