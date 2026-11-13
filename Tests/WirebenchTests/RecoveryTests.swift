import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
@testable import WirebenchSource

/// Recovery: a project back to Structured Text, and the recovered text compiled again.
@Suite("Structured Text recovery")
struct RecoveryTests {
    static func block(_ name: String, id: Int, order: Int) -> PCCModule {
        BlockFactory.makeModule(guid: BlockTypeCatalog.info(forBlockName: name)!.guid, id: id, name: "\(name)\(id)",
                                x: 0, y: 0, order: order, threadId: 1, page: "Page")
    }

    static func project(_ modules: [PCCModule], wires: [Connection] = []) -> PCCProject {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        project.modules = modules
        project.inConnections = wires
        return project
    }

    @Test("A compiled program recovers to source that compiles to the same pages and pins")
    func roundTrip() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM Gate
        VAR
            a AT %IX0 : BOOL;
            b AT %IX1 : BOOL;
            lamp AT %QX2 : BOOL;
        END_VAR
            lamp := a AND NOT b;
        END_PROGRAM
        """)
        let source = PCCDecompiler().source(for: compiled.project)
        #expect(source.contains("PROGRAM Gate"))
        #expect(source.contains("AT %IX0"))
        #expect(source.contains("AT %QX2"))
        let again = try SourceCompiler().compile(source)
        #expect(again.pages == compiled.project.pages.map(\.caption))
        #expect(again.usedInputs == [0, 1])
        #expect(again.writtenOutputs == [2])
    }

    @Test("An if/else of Set writes comes back as IF/ELSE")
    func conditionalRecovery() throws {
        var project = Self.project([Self.block("8xDI", id: 1, order: 10),
                                    Self.block("If", id: 2, order: 20),
                                    Self.block("Set", id: 3, order: 30),
                                    Self.block("Else", id: 4, order: 40),
                                    Self.block("Set", id: 5, order: 50),
                                    Self.block("EndIf", id: 6, order: 60),
                                    Self.block("8xDO", id: 7, order: 70),
                                    Self.block("BoolVar", id: 8, order: 80)])
        let di = project.modules[0], ifBlock = project.modules[1], thenSet = project.modules[2]
        let elseSet = project.modules[4], out = project.modules[6]
        let variable = project.modules[7]
        project.inConnections = [
            Connection(inModuleId: ifBlock.id, inPinId: 0, outModuleId: di.id, outPinId: 0),
            Connection(inModuleId: thenSet.id, inPinId: 1, outModuleId: di.id, outPinId: 1),
            Connection(inModuleId: thenSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
            Connection(inModuleId: elseSet.id, inPinId: 1, outModuleId: di.id, outPinId: 2),
            Connection(inModuleId: elseSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
            Connection(inModuleId: out.id, inPinId: 1, outModuleId: variable.id, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("IF di0 THEN"))
        #expect(source.contains("ELSE"))
        #expect(source.contains("END_IF;"))
        _ = try SourceCompiler().compile(source)
    }

    @Test("A block with a fractional float parameter is listed, not truncated")
    func fractionalParameterIsNotTruncated() throws {
        var writer = Self.block("D3NWFloat", id: 2, order: 20)
        writer.paramPins[2].value = .float(0.5)
        let project = Self.project([Self.block("8xDI", id: 1, order: 10), writer,
                                    Self.block("8xDO", id: 3, order: 30)],
                                   wires: [Connection(inModuleId: 3, inPinId: 1, outModuleId: 2, outPinId: 0)])
        let source = PCCDecompiler().source(for: project)
        #expect(!source.contains(": D3NWFloat;"))
        #expect(source.contains("Not recovered"))
    }

    @Test("A constant on an unwired pin is recovered as a number, by the pin's type")
    func constantsAreWritten() throws {
        var add = Self.block("IAdd", id: 2, order: 20)
        add.inPins[2].value = .int32(5)
        let project = Self.project([Self.block("8xDI", id: 1, order: 10), add,
                                    Self.block("8xDO", id: 3, order: 30)],
                                   wires: [Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 0),
                                           Connection(inModuleId: 3, inPinId: 1, outModuleId: 2, outPinId: 0)])
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("X1 := 5"))
        let again = try SourceCompiler().compile(source)
        let read = try #require(again.project.modules.first {
            $0.guid == BlockTypeCatalog.info(forBlockName: "IAdd")!.guid
        })
        #expect(read.inPins[2].value == .int32(5))
    }

    @Test("Two 8xDI or 8xDO blocks are not flattened into one")
    func twoIOBlocks() throws {
        let project = Self.project([Self.block("8xDI", id: 1, order: 10), Self.block("8xDI", id: 2, order: 20),
                                    Self.block("8xDO", id: 3, order: 30), Self.block("8xDO", id: 4, order: 40),
                                    Self.block("And", id: 5, order: 50)],
                                   wires: [Connection(inModuleId: 5, inPinId: 1, outModuleId: 1, outPinId: 0),
                                           Connection(inModuleId: 5, inPinId: 2, outModuleId: 2, outPinId: 0),
                                           Connection(inModuleId: 3, inPinId: 1, outModuleId: 5, outPinId: 0),
                                           Connection(inModuleId: 4, inPinId: 1, outModuleId: 5, outPinId: 0)])
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains(": _8xDI;"))
        #expect(source.contains(": _8xDO;"))
        let again = try SourceCompiler().compile(source)
        #expect(again.project.modules.filter { $0.guid == EightDIBlock.guid }.count == 2)
        #expect(again.project.modules.filter { $0.guid == EightDOBlock.guid }.count == 2)
    }

    @Test("A nested conditional is not recovered as a flattened one")
    func nestedConditional() throws {
        var project = Self.project([Self.block("8xDI", id: 1, order: 10),
                                    Self.block("If", id: 2, order: 20), Self.block("If", id: 3, order: 30),
                                    Self.block("Set", id: 4, order: 40), Self.block("EndIf", id: 5, order: 50),
                                    Self.block("Else", id: 6, order: 60), Self.block("Set", id: 7, order: 70),
                                    Self.block("EndIf", id: 8, order: 80), Self.block("BoolVar", id: 9, order: 90)])
        let di = project.modules[0], outer = project.modules[1], inner = project.modules[2]
        let innerSet = project.modules[3], innerEnd = project.modules[4]
        let elseBlock = project.modules[5], outerSet = project.modules[6]
        let outerEnd = project.modules[7], variable = project.modules[8]
        project.inConnections = [
            Connection(inModuleId: outer.id, inPinId: 0, outModuleId: di.id, outPinId: 0),
            Connection(inModuleId: inner.id, inPinId: 0, outModuleId: di.id, outPinId: 1),
            Connection(inModuleId: innerSet.id, inPinId: 1, outModuleId: di.id, outPinId: 2),
            Connection(inModuleId: innerSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
            Connection(inModuleId: outerSet.id, inPinId: 1, outModuleId: di.id, outPinId: 3),
            Connection(inModuleId: outerSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
        ]
        _ = (innerEnd, elseBlock, outerEnd)
        let source = PCCDecompiler().source(for: project)
        #expect(!source.contains("IF di0 THEN"))
        #expect(source.contains("Conditional blocks"))
    }

    @Test("A macro-only project recovers to a source that compiles")
    func macroOnlyProject() throws {
        guard let url = TestCorpus.project(named: "binarni odcitacka.pcc") else { return }
        let project = try PCCParser().parse(fileAt: url)
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("PROGRAM Main"))
        #expect(source.contains("FUNCTION_BLOCK"))
        _ = try SourceCompiler().compile(source)
    }

    @Test("A self-wired counter keeps its wire through recovery")
    func selfWire() throws {
        var project = Self.project([Self.block("AdvCounter", id: 1, order: 10)])
        #expect(project.connect(outModuleId: 1, outPinId: 1, toModuleId: 1, inPinId: 2) == nil)
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains(":= AdvCounter1.High"))
        let again = try SourceCompiler().compile(source)
        let wire = try #require(again.project.inConnections.first)
        #expect(wire.outModuleId == wire.inModuleId)
        #expect(wire.inPinId == 2)
    }

    @Test("Digital I/O is recovered by hardware channel, not by pin position")
    func maskedIOChannels() throws {
        var project = Self.project([Self.block("8xDI", id: 1, order: 10),
                                    Self.block("8xDO", id: 2, order: 20),
                                    Self.block("And", id: 3, order: 30)])
        let di = project.modules[0], out = project.modules[1], and = project.modules[2]
        project.modules[0].rawAttributes["PIN_MASK"] = "$0030"      // DI4 and DI5
        project.modules[1].rawAttributes["PIN_COUNT"] = "8"
        project.modules[1].rawAttributes["HIDDEN_PIN_MASK"] = "$0001" // DO1…DO7
        project.inConnections = [
            Connection(inModuleId: and.id, inPinId: 1, outModuleId: di.id, outPinId: 0),
            Connection(inModuleId: out.id, inPinId: 1, outModuleId: and.id, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("AT %IX4"), "the first exposed input is DI4, not DI0")
        #expect(source.contains("AT %QX1"), "DO0 is hidden, so the first output is DO1")
        _ = try SourceCompiler().compile(source)
    }

    @Test("A typed block output is listed, not recovered as a Boolean wire")
    func typedOutputIsListed() throws {
        var project = Self.project([Self.block("IAdd", id: 1, order: 10),
                                    Self.block("IntVar", id: 2, order: 20),
                                    Self.block("Set", id: 3, order: 30),
                                    Self.block("8xDO", id: 4, order: 40)])
        project.inConnections = [
            Connection(inModuleId: 3, inPinId: 1, outModuleId: 1, outPinId: 0),
            Connection(inModuleId: 3, inPinId: 2, outModuleId: 2, outPinId: 0),
            Connection(inModuleId: 4, inPinId: 1, outModuleId: 2, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(!source.contains(":= IntVar1.Y"), "a typed output must not become a Boolean assignment")
        #expect(source.contains("Not recovered"))
        _ = try SourceCompiler().compile(source)
    }

    @Test("A real project recovers to a source that compiles")
    func realProject() throws {
        guard let url = TestCorpus.project(named: "kostka-1.pcc") else { return }
        let project = try PCCParser().parse(fileAt: url)
        let source = PCCDecompiler().source(for: project)
        let again = try SourceCompiler().compile(source)
        #expect(again.pages.count >= project.pages.count)
    }
}
