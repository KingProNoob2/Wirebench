import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
@testable import WirebenchSource

/// Regressions from the whole-project audit.
@Suite("Structured Text audit regressions")
struct StructuredTextAuditTests {
    private func error(_ source: String) -> String? {
        do { _ = try SourceCompiler().compile(source); return nil } catch { return "\(error)" }
    }

    @Test("ELSIF chains parse: the outer IF owns the closing END_IF")
    func elsifChain() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR
            a AT %IX0 : BOOL;
            b AT %IX1 : BOOL;
            lamp AT %QX0 : BOOL;
        END_VAR
            IF a THEN
                lamp := TRUE;
            ELSIF b THEN
                lamp := FALSE;
            ELSE
                lamp := a;
            END_IF;
        END_PROGRAM
        """)
        #expect(compiled.project.modules.count > 2)
    }

    @Test("Comments nest, so a commented-out comment cannot end the comment early")
    func nestedComments() throws {
        _ = try SourceCompiler().compile("""
        (* outer (* inner *) still commented *)
        PROGRAM P
        VAR a AT %IX0 : BOOL; lamp AT %QX0 : BOOL; END_VAR
            lamp := a; (* one (* two *) three *)
        END_PROGRAM
        """)
    }

    @Test("A CRLF source compiles and its // comments end at the line break")
    func crlfSource() throws {
        let source = "PROGRAM P\r\nVAR a AT %IX0 : BOOL; lamp AT %QX0 : BOOL; END_VAR\r\nlamp := a; // note\r\nEND_PROGRAM\r\n"
        _ = try SourceCompiler().compile(source)
    }

    @Test("Calling an instance twice is refused instead of merging the calls")
    func doubleCall() throws {
        let message = try #require(error("""
        FUNCTION_BLOCK Invert
        VAR_INPUT value : BOOL; END_VAR
        VAR_OUTPUT result : BOOL; END_VAR
            result := NOT value;
        END_FUNCTION_BLOCK
        PROGRAM P
        VAR a AT %IX0 : BOOL; t : Invert; END_VAR
            t(value := a);
            t(value := FALSE);
        END_PROGRAM
        """))
        #expect(message.contains("called twice"))
    }

    @Test("An instance that is never called is not emitted, and reading its output is refused")
    func uncalledInstance() throws {
        let compiled = try SourceCompiler().compile("""
        FUNCTION_BLOCK Invert
        VAR_INPUT value : BOOL; END_VAR
        VAR_OUTPUT result : BOOL; END_VAR
            result := NOT value;
        END_FUNCTION_BLOCK
        PROGRAM P
        VAR a AT %IX0 : BOOL; t : Invert; END_VAR
        END_PROGRAM
        """)
        #expect(compiled.project.modules.filter { $0.guid == MacroInterface.callGUID }.isEmpty)
        let message = try #require(error("""
        FUNCTION_BLOCK Invert
        VAR_INPUT value : BOOL; END_VAR
        VAR_OUTPUT result : BOOL; END_VAR
            result := NOT value;
        END_FUNCTION_BLOCK
        PROGRAM P
        VAR a AT %IX0 : BOOL; lamp AT %QX0 : BOOL; t : Invert; END_VAR
            lamp := t.result;
        END_PROGRAM
        """))
        #expect(message.contains("read before it is called"))
    }

    @Test("An output written only inside IF, or read before it is assigned, is refused")
    func outputRules() throws {
        let conditional = try #require(error("""
        PROGRAM P
        VAR a AT %IX0 : BOOL; lamp AT %QX0 : BOOL; END_VAR
            IF a THEN
                lamp := TRUE;
            END_IF;
        END_PROGRAM
        """))
        #expect(conditional.contains("only inside IF"))
        let earlyRead = try #require(error("""
        PROGRAM P
        VAR lamp AT %QX0 : BOOL; END_VAR
            lamp := lamp OR TRUE;
        END_PROGRAM
        """))
        #expect(earlyRead.contains("read before it is assigned"))
    }

    @Test("A call runs after the blocks that feed it")
    func callOrder() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR a AT %IX0 : BOOL; lamp AT %QX0 : BOOL; sum : IAdd; END_VAR
            sum(X0 := a, X1 := 5);
            lamp := sum.Y;
        END_PROGRAM
        """)
        let di = try #require(compiled.project.modules.first { $0.guid == EightDIBlock.guid })
        let add = try #require(compiled.project.modules.first { $0.guid == BlockTypeCatalog.info(forBlockName: "IAdd")!.guid })
        #expect(add.order > di.order, "the adder must run after the input it reads")
    }

    @Test("A zero-argument block recovers with an empty argument list and compiles")
    func zeroArgumentCall() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        project.modules = [BlockFactory.makeModule(guid: BlockTypeCatalog.info(forBlockName: "IntVar")!.guid,
                                                   id: 1, name: "IntVar1", x: 0, y: 0, order: 10,
                                                   threadId: 1, page: "Page")]
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("IntVar1()"))
        _ = try SourceCompiler().compile(source)
    }

    @Test("A block whose real layout differs from the help's pin table uses the factory layout")
    func factoryLayout() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR cmd : SystemCmd; END_VAR
            cmd(Par1 := 770, Par2 := 112);
        END_PROGRAM
        """)
        let command = try #require(compiled.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "SystemCmd")!.guid
        })
        #expect(command.inPins.count == 2, "En and Cmd, not the help's four inputs")
        #expect(command.paramPins[0].value == .int32(770))
        #expect(command.paramPins[1].value == .int32(112))
        let source = PCCDecompiler().source(for: compiled.project)
        #expect(source.contains("Par1 := 770"))
        _ = try SourceCompiler().compile(source)
    }

    @Test("An inverted input pin is recovered as NOT")
    func invertedPin() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        let di = BlockFactory.makeModule(guid: EightDIBlock.guid, id: 1, name: "8xDI1", x: 0, y: 0,
                                         order: 10, threadId: 1, page: "Page")
        var out = BlockFactory.makeModule(guid: EightDOBlock.guid, id: 2, name: "8xDO1", x: 200, y: 0,
                                          order: 20, threadId: 1, page: "Page")
        out.inPins[1].inverted = true
        project.modules = [di, out]
        project.inConnections = [Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 0)]
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("NOT ("))
        _ = try SourceCompiler().compile(source)
    }
}
