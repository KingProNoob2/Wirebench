import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
@testable import WirebenchSource

/// Bugs found while hunting through the compiler, decompiler and serializer: each test would have caught one.
@Suite("Bug hunting")
struct BugHuntTests {
    private func error(_ source: String) -> String? {
        do { _ = try SwiftSourceCompiler().compile(source); return nil }
        catch { return "\(error)" }
    }

    private func block(_ name: String, id: Int, order: Int, page: String = "Page") -> PCCModule {
        BlockFactory.makeModule(guid: BlockTypeCatalog.info(forBlockName: name)!.guid, id: id, name: "\(name)\(id)",
                                x: 0, y: 0, order: order, threadId: 1, page: page)
    }

    @Test("A huge coordinate clamps instead of trapping the save")
    func hugeCoordinateDoesNotTrap() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [BlockFactory.makeModule(guid: AndBlock.guid, id: 1, name: "And1",
                                                   x: 1e300, y: -.infinity, order: 10, threadId: 1, page: "main")]
        let xml = PCCSerializer().serialize(project: project)
        #expect(xml.contains("X=\"1000000000\""))
        #expect(xml.contains("Y=\"0\""))
    }

    @Test("set() cannot name a pin the block does not have")
    func setPinIsBounded() throws {
        let message = try #require(error("""
        struct P { @DO(0) var x: Bool
        func scan() {
            let a = Block.And(true, true, true)
            a.set(200000, true)
            x = a.Y
        } }
        """))
        #expect(message.contains("has no input pin"))
        let notPin = try #require(error("""
        struct P { @DO(0) var x: Bool
        func scan() {
            let a = Block.Not(true)
            a.set(2, true)
            x = a.Y
        } }
        """))
        #expect(notPin.contains("has no input pin"))
    }

    @Test("A block call with more arguments than the block has inputs is refused")
    func extraArgumentsAreRefused() throws {
        let message = try #require(error("""
        struct P { @DO(0) var x: Bool
        func scan() {
            let n = Block.Not(true, true, true)
            x = n.Y
        } }
        """))
        #expect(message.contains("at most"))
    }

    @Test("return with a value is refused")
    func returnValueIsRefused() throws {
        let message = try #require(error("""
        struct P { @DO(0) var x: Bool
        func scan() { return true } }
        """))
        #expect(message.contains("returns nothing"))
    }

    @Test("Two 8xDI (or 8xDO) blocks are not flattened into one")
    func twoIOBlocks() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        let di1 = block("8xDI", id: 1, order: 10), di2 = block("8xDI", id: 2, order: 20)
        let do1 = block("8xDO", id: 3, order: 30), do2 = block("8xDO", id: 4, order: 40)
        let and = block("And", id: 5, order: 50)
        project.modules = [di1, di2, do1, do2, and]
        project.inConnections = [
            Connection(inModuleId: and.id, inPinId: 1, outModuleId: di1.id, outPinId: 0),
            Connection(inModuleId: and.id, inPinId: 2, outModuleId: di2.id, outPinId: 0),
            Connection(inModuleId: do1.id, inPinId: 1, outModuleId: and.id, outPinId: 0),
            Connection(inModuleId: do2.id, inPinId: 1, outModuleId: and.id, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("Block._8xDI"))
        #expect(source.contains("Block._8xDO"))
        // A `@DI` pin exists once, for the first block only; the second is a library block.
        #expect(source.components(separatedBy: "@DI(0)").count == 2)
        let again = try SwiftSourceCompiler().compile(source)
        #expect(again.project.modules.filter { $0.guid == EightDIBlock.guid }.count == 2)
        #expect(again.project.modules.filter { $0.guid == EightDOBlock.guid }.count == 2)
    }

    @Test("An unwired integer pin is recovered as a number, not as true")
    func integerConstantIsANumber() throws {
        var project = PCCProject(name: "C", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        let di = block("8xDI", id: 1, order: 10)
        var add = block("IAdd", id: 2, order: 20)
        add.inPins[2].value = .int32(5)
        let out = block("8xDO", id: 3, order: 30)
        project.modules = [di, add, out]
        project.inConnections = [
            Connection(inModuleId: add.id, inPinId: 1, outModuleId: di.id, outPinId: 0),
            Connection(inModuleId: out.id, inPinId: 1, outModuleId: add.id, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("5"))
        #expect(!source.contains("true, di0, true"))
        let again = try SwiftSourceCompiler().compile(source)
        let read = try #require(again.project.modules.first { $0.guid == BlockTypeCatalog.info(forBlockName: "IAdd")!.guid })
        #expect(read.inPins[2].value == .int32(5))
    }

    @Test("A fractional float parameter is not silently truncated when recovering")
    func fractionalParameterIsNotTruncated() throws {
        var project = PCCProject(name: "F", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        let di = block("8xDI", id: 1, order: 10)
        var writer = block("D3NWFloat", id: 2, order: 20)
        writer.paramPins[2].value = .float(0.5)
        let out = block("8xDO", id: 3, order: 30)
        project.modules = [di, writer, out]
        project.inConnections = [
            Connection(inModuleId: out.id, inPinId: 1, outModuleId: writer.id, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(!source.contains("Block.D3NWFloat"))
        #expect(source.contains("Not recovered"))
    }

    @Test("A block created inside if is refused instead of crashing")
    func blockInsideBranch() throws {
        let message = try #require(error("""
        struct P { @DI(0) var a: Bool
        @DO(0) var x: Bool
        func scan() {
            if a {
                let b = Block.And(true, true, true)
                x = b.Y
            }
        } }
        """))
        #expect(message.contains("inside 'if'"))
        #expect(message.contains("create it before the branch"))
    }

    @Test("Wiring a block inside if is refused")
    func setInsideBranch() throws {
        let message = try #require(error("""
        struct P { @DI(0) var a: Bool
        @DO(0) var x: Bool
        func scan() {
            let b = Block.And(true, true, true)
            if a { b.set(1, false) }
            x = b.Y
        } }
        """))
        #expect(message.contains("cannot be inside 'if'"))
    }

    @Test("A nested conditional is not recovered as a flattened one")
    func nestedConditionalIsNotFlattened() throws {
        var project = PCCProject(name: "N", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "Page")]
        let di = block("8xDI", id: 1, order: 10)
        let outerIf = block("If", id: 2, order: 20), innerIf = block("If", id: 3, order: 30)
        let innerSet = block("Set", id: 4, order: 40), innerEnd = block("EndIf", id: 5, order: 50)
        let elseB = block("Else", id: 6, order: 60), outerSet = block("Set", id: 7, order: 70)
        let outerEnd = block("EndIf", id: 8, order: 80), variable = block("BoolVar", id: 9, order: 90)
        project.modules = [di, outerIf, innerIf, innerSet, innerEnd, elseB, outerSet, outerEnd, variable]
        project.inConnections = [
            Connection(inModuleId: outerIf.id, inPinId: 0, outModuleId: di.id, outPinId: 0),
            Connection(inModuleId: innerIf.id, inPinId: 0, outModuleId: di.id, outPinId: 1),
            Connection(inModuleId: innerSet.id, inPinId: 1, outModuleId: di.id, outPinId: 2),
            Connection(inModuleId: innerSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
            Connection(inModuleId: outerSet.id, inPinId: 1, outModuleId: di.id, outPinId: 3),
            Connection(inModuleId: outerSet.id, inPinId: 2, outModuleId: variable.id, outPinId: 0),
        ]
        let source = PCCDecompiler().source(for: project)
        #expect(!source.contains("if di0 {"))
        #expect(source.contains("Conditional blocks"))
    }
}
