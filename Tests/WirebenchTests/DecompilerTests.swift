import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
@testable import WirebenchSource

/// The other direction: a project back into source, for a document that carries none.
@Suite("PLC Swift recovery")
struct DecompilerTests {
    private static let kostka = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/kostka-1.pcc")

    @Test("A compiled project recovers to source that compiles to the same pages and pins")
    func roundTrip() throws {
        let compiled = try SwiftSourceCompiler().compile("""
        @main
        struct Gate {
            @DI(0) var a: Bool
            @DI(1) var b: Bool
            @DO(2) var lamp: Bool
            var on: Bool = false

            func scan() {
                if a { on = !on }
                lamp = on && !b
            }
        }
        """)
        let source = PCCDecompiler().source(for: compiled.project)
        let again = try SwiftSourceCompiler().compile(source)
        #expect(again.pages == compiled.pages)
        #expect(again.usedInputs == compiled.usedInputs)
        #expect(again.writtenOutputs == compiled.writtenOutputs)
        #expect(again.variables.count == compiled.variables.count, "a variable's block name is not its source name")
    }

    @Test("A macro page comes back as a @macro struct, and its calls as calls")
    func macroRoundTrip() throws {
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
        let source = PCCDecompiler().source(for: compiled.project)
        #expect(source.contains("@macro"))
        #expect(source.contains("Toggle(value:"))
        let again = try SwiftSourceCompiler().compile(source)
        #expect(again.pages == ["Main", "*Toggle"])
        #expect(again.macros.map(\.inputs) == [["value"]])
        #expect(again.macros.map(\.outputs) == [["result"]])
    }

    @Test("A real project recovers to source that compiles, keeping its pages")
    func realProject() throws {
        let project = try PCCParser().parse(fileAt: Self.kostka)
        let source = PCCDecompiler().source(for: project)
        #expect(source.contains("@main"))
        let again = try SwiftSourceCompiler().compile(source)
        #expect(again.pages.count == project.pages.count)
        #expect(!source.isEmpty)
    }
}
