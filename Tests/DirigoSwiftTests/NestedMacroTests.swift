import Testing
import Foundation
import DirigoCore
import DirigoLibrary
import DirigoEngine
import DirigoHardware

/// A macro that calls another macro: `Main` calls `*A`, which calls `*B`, which inverts its input.
///
///     Main:  Src ──► A1 ──► Probe
///     *A:    Inputs ──► B1 ──► Outputs
///     *B:    Inputs ──► Not ──► Outputs
@Suite("Nested macros")
struct NestedMacroTests {
    static func project() -> PCCProject {
        var project = PCCProject(name: "nested")
        project.pages = [ProjectPage(caption: "Main"), ProjectPage(caption: "*A"), ProjectPage(caption: "*B")]
        project.appOptions.cycleDelay = 10
        func call(_ id: Int, _ name: String, _ macro: String, page: String, order: Int) -> PCCModule {
            PCCModule(id: id, guid: MacroBlock.guid, name: name, x: 0, y: 0, order: order,
                      threadId: page.hasPrefix("*") ? 0 : 1, page: page,
                      inPins: [Pin(id: 0, value: .bool(false))], outPins: [Pin(id: 0, value: .bool(false))],
                      rawAttributes: ["MACRO_NAME": macro])
        }
        func inputs(_ id: Int, page: String) -> PCCModule {
            PCCModule(id: id, guid: InputsBlock.guid, name: "Inputs\(id)", x: 0, y: 0, order: 10,
                      threadId: 0, page: page, inPins: [], outPins: [Pin(id: 0, value: .bool(false))],
                      rawAttributes: ["MACRO_NAME": "Inputs", "KIND": "0"])
        }
        func outputs(_ id: Int, page: String) -> PCCModule {
            PCCModule(id: id, guid: OutputsBlock.guid, name: "Outputs\(id)", x: 0, y: 0, order: 90,
                      threadId: 0, page: page, inPins: [Pin(id: 0, value: .bool(false))], outPins: [],
                      rawAttributes: ["MACRO_NAME": "Outputs", "KIND": "1"])
        }
        project.modules = [
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "Src", x: 0, y: 0, order: 10, threadId: 1, page: "Main",
                      inPins: [], outPins: [Pin(id: 0, value: .bool(false))]),
            call(2, "A1", "A", page: "Main", order: 20),
            PCCModule(id: 3, guid: NotBlock.guid, name: "Probe", x: 0, y: 0, order: 30, threadId: 1, page: "Main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            inputs(10, page: "*A"), call(11, "B1", "B", page: "*A", order: 20), outputs(12, page: "*A"),
            inputs(20, page: "*B"),
            PCCModule(id: 21, guid: NotBlock.guid, name: "Not1", x: 0, y: 0, order: 20, threadId: 0, page: "*B",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            outputs(22, page: "*B"),
        ]
        func wire(_ from: Int, _ to: Int, pin: Int = 0) -> Connection {
            Connection(inModuleId: to, inPinId: pin, outModuleId: from, outPinId: 0, isParam: false)
        }
        project.inConnections = [
            wire(1, 2), wire(2, 3, pin: 1),
            wire(10, 11), wire(11, 12),
            wire(20, 21, pin: 1), wire(21, 22),
        ]
        return project
    }

    @Test("A value crosses two macro levels and back, in the Swift engine")
    func swiftEngine() throws {
        let engine = SimulationEngine(project: Self.project(), scheduling: .everyTick)
        engine.step()
        // Src is false, `*B` inverts it, and `A1`'s output is what came back.
        #expect(engine.getNode(id: 2)?.block.outPins.first?.asBool == true)
        // And the main sheet's `Not` reads it.
        #expect(engine.getNode(id: 3)?.block.outPins.first?.asBool == false)
    }

    @Test("Both engines agree on nested macros")
    func enginesAgree() throws {
        let project = Self.project()
        #expect(MacroCalls.nestingDepth(in: project.modules) == 2)
        #expect(CxxSimulationCore.macroBridges(in: project).count == 4, "an Inputs and an Outputs per call")
        try CxxSimulationTests.compareBothEngines(project, label: "nested macros")
    }

    @Test("Nesting depth: none, one level, two")
    func depth() {
        var project = Self.project()
        #expect(MacroCalls.nestingDepth(in: project.modules) == 2)
        project.modules.removeAll { $0.id == 11 }           // `*A` no longer calls `*B`
        #expect(MacroCalls.nestingDepth(in: project.modules) == 1)
        project.modules.removeAll { $0.id == 2 }
        #expect(MacroCalls.nestingDepth(in: project.modules) == 0)
    }

    @Test("The compiler reaches a sheet that only another sheet calls, and expands it in place")
    func compilerExpandsNested() throws {
        let xml = PCCSerializer().serialize(project: Self.project())
        let modules = PLCProjectCompiler.modules(in: xml)
        let program = PLCProjectCompiler.programModules(modules).map(\.name)
        #expect(program.contains("Not1"), "`*B` is called only from `*A`, and is still in the program: \(program)")
        let order = PLCProjectCompiler.expansionOrder(modules).map(\.name)
        let a = try #require(order.firstIndex(of: "A1"))
        let b = try #require(order.firstIndex(of: "B1"))
        let n = try #require(order.firstIndex(of: "Not1"))
        #expect(a < b && b < n, "A1's sheet, then B1's sheet, in place: \(order)")
        #expect(order.firstIndex(of: "Probe")! > n, "the main sheet carries on after the whole expansion")
    }

    @Test("A sheet that calls itself does not loop")
    func selfCallTerminates() {
        var project = Self.project()
        project.modules.append(PCCModule(id: 30, guid: MacroBlock.guid, name: "Loop", x: 0, y: 0, order: 50,
                                         threadId: 0, page: "*B",
                                         inPins: [Pin(id: 0, value: .bool(false))],
                                         outPins: [Pin(id: 0, value: .bool(false))],
                                         rawAttributes: ["MACRO_NAME": "B"]))
        #expect(MacroCalls.nestingDepth(in: project.modules) >= 2)
        let xml = PCCSerializer().serialize(project: project)
        let modules = PLCProjectCompiler.modules(in: xml)
        #expect(!PLCProjectCompiler.expansionOrder(modules).isEmpty)
        let engine = SimulationEngine(project: project, scheduling: .everyTick)
        engine.step()
    }
    // MARK: - One copy of the sheet per call

    /// `project()` with a second call of `*A` (`A2`, id 4) whose input is a constant `true`, where `A1` is
    /// fed `false`. `*A` calls `*B` once and `*B` inverts, so `A1` must answer `true` and `A2` `false`.
    static func twoCalls() -> PCCProject {
        var project = project()
        project.modules.append(PCCModule(
            id: 4, guid: MacroBlock.guid, name: "A2", x: 0, y: 0, order: 25, threadId: 1, page: "Main",
            inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .bool(false))],
            rawAttributes: ["MACRO_NAME": "A"]))
        return project
    }

    @Test("Two calls of one macro see independent copies, in the Swift engine")
    func swiftCallsAreIndependent() {
        let engine = SimulationEngine(project: Self.twoCalls(), scheduling: .everyTick)
        for _ in 0..<3 { engine.step() }
        #expect(engine.getNode(id: 2)?.block.outPins.first?.asBool == true)
        #expect(engine.getNode(id: 4)?.block.outPins.first?.asBool == false)
    }

    @Test("Two calls of one macro see independent copies, in the C++ core")
    func cxxCallsAreIndependent() {
        let project = Self.twoCalls()
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        for _ in 0..<3 { core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0)) }
        #expect(core.outValue(moduleId: 2, pin: 0)?.asBool == true)
        #expect(core.outValue(moduleId: 4, pin: 0)?.asBool == false)
    }

    /// `project()` plus a sheet `*C` that nothing calls and that calls `*A` with an input of `true`. That call
    /// never runs, so `A1`'s answer must not change — its input used to be overwritten by the stray call's.
    static func strayCall() -> PCCProject {
        var project = project()
        project.pages.append(ProjectPage(caption: "*C"))
        project.modules.append(PCCModule(
            id: 5, guid: MacroBlock.guid, name: "Stray", x: 0, y: 0, order: 10, threadId: 0, page: "*C",
            inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .bool(false))],
            rawAttributes: ["MACRO_NAME": "A"]))
        return project
    }

    @Test("A call on a sheet nothing calls does not feed the macro a real call is using")
    func strayCallIsIgnored() {
        let engine = SimulationEngine(project: Self.strayCall(), scheduling: .everyTick)
        for _ in 0..<3 { engine.step() }
        #expect(engine.getNode(id: 2)?.block.outPins.first?.asBool == true, "A1: Src is false, B inverts")
        let core = CxxSimulationCore(project: Self.strayCall(), profileScheduling: false)
        for _ in 0..<3 { core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0)) }
        #expect(core.outValue(moduleId: 2, pin: 0)?.asBool == true)
    }

    @Test("Both engines agree when a macro is called twice")
    func enginesAgreeOnTwoCalls() throws {
        try CxxSimulationTests.compareBothEngines(Self.twoCalls(), label: "two calls")
    }

    @Test("Instancing leaves a project with one call per macro alone, and clones a repeated call")
    func instancingClones() {
        let single = Self.project()
        #expect(MacroInstancing.instanced(single) == single)
        let doubled = MacroInstancing.instanced(Self.twoCalls())
        // `A2` gets `*A#1` (3 modules) and that sheet's call of `B` gets `*B#2` (3 modules).
        #expect(doubled.modules.count == Self.twoCalls().modules.count + 6)
        #expect(doubled.modules.first { $0.id == 4 }?.rawAttributes["MACRO_NAME"] == "A#1")
        #expect(doubled.modules.first { $0.id == 2 }?.rawAttributes["MACRO_NAME"] == "A", "the first call keeps the sheet")
    }

    @Test("The compiler expands each call of a macro into its own modules")
    func compilerCopiesPerCall() throws {
        let xml = PCCSerializer().serialize(project: Self.twoCalls())
        let (modules, wires) = PLCProjectCompiler.instanced(
            modules: PLCProjectCompiler.modules(in: xml), wires: PLCProjectCompiler.wires(in: xml))
        let order = PLCProjectCompiler.expansionOrder(modules)
        #expect(order.filter { $0.name == "Not1" }.count == 2, "`*B` is expanded under each call of `*A`")
        #expect(Set(order.map(\.umisteni)).count == order.count, "every expanded module has its own id")
        let resolved = PLCProjectCompiler.resolvingMacroInterfaces(modules: modules, wires: wires)
        let a1 = try #require(modules.first { $0.name == "A1" }), a2 = try #require(modules.first { $0.name == "A2" })
        let notIDs = order.filter { $0.name == "Not1" }.map(\.umisteni)
        // Each `Not1` reads what feeds its own chain's call, so the two do not read the same source.
        let sources = notIDs.compactMap { id in resolved.first { $0.inModule == id && $0.inPin == 1 }?.outModule }
        #expect(sources.count == 2 && sources[0] != sources[1], "\(sources) \(a1.umisteni) \(a2.umisteni)")
    }
}
