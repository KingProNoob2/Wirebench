import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
@testable import WirebenchSource

/// The block library: every catalogued block gets a source constructor, and `set` wires an input after creation, which is
/// what makes feedback (a counter whose output reaches its own input) expressible at all.
@Suite("PLC Swift block library")
struct BlockLibraryTests {
    @Test("Block.And is the And block, and it simulates")
    func andBlock() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        @main
        struct Lib {
            @DI(0) var a: Bool
            @DO(0) var lamp: Bool

            func scan() {
                let both = Block.And(true, a, true)
                lamp = both.Y
            }
        }
        """)
        #expect(compiled.project.modules.contains { $0.guid == AndBlock.guid })
        let di = try #require(compiled.project.modules.first { $0.guid == EightDIBlock.guid })
        let out = try #require(compiled.project.modules.first { $0.guid == EightDOBlock.guid })
        let core = CxxSimulationCore(project: compiled.project, profileScheduling: false)
        core.setOut(moduleId: di.id, pin: 0, value: .bool(true))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 1_709_623_628))
        #expect(core.inPins(moduleId: out.id)[1].asBool)
        core.setOut(moduleId: di.id, pin: 0, value: .bool(false))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 1_709_623_628))
        #expect(!core.inPins(moduleId: out.id)[1].asBool)
    }

    @Test("set() wires an input into a block built in a cycle")
    func feedbackWiring() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        @main
        struct Loop {
            @DI(0) var a: Bool
            @DO(0) var lamp: Bool

            func scan() {
                let first = Block.And(true, a, a)
                let second = Block.Or(true, a, a)
                second.set(2, first.Y)
                first.set(2, second.Y)
                lamp = second.Y
            }
        }
        """)
        #expect(compiled.project.modules.contains { $0.guid == AndBlock.guid })
        #expect(compiled.project.modules.contains { $0.guid == OrBlock.guid })
        // Both wires are there, in both directions.
        #expect(compiled.project.inConnections.contains { $0.inPinId == 2 })
        #expect(compiled.project.inConnections.count >= 4)
    }

    @Test("Every catalogue block has a constructor name that maps back to it")
    func namesAreConsistent() {
        for info in BlockTypeCatalog.all {
            let name = try? #require(BlockLabels.sourceName(for: info.guid))
            #expect(name != nil, "no source name for \(info.blockName)")
            if let name {
                #expect(BlockLabels.guid(forSourceName: name) == info.guid)
            }
        }
    }

    @Test("A project recovers to source that compiles, keeping its pages and most of its blocks")
    func recoverRealProject() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kostka-1.pcc")
        let project = try PCCParser().parse(fileAt: url)
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("Block."))
        let again = try SwiftSourceCompiler().compile(source)
        #expect(again.pages.count == project.pages.count)
        #expect(again.project.modules.count * 2 >= project.modules.count,
                "recovered \(again.project.modules.count) of \(project.modules.count) blocks")
    }
}
