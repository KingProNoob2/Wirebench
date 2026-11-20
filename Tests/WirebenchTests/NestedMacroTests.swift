import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
@testable import WirebenchHardware

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
        let engine = TestEngine(project: Self.project(), scheduling: .everyTick)
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
        let engine = TestEngine(project: project, scheduling: .everyTick)
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
        let engine = TestEngine(project: Self.twoCalls(), scheduling: .everyTick)
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
        let engine = TestEngine(project: Self.strayCall(), scheduling: .everyTick)
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
        let (resolvedModules, resolved) = PLCProjectCompiler.expandingMacroInterfaces(modules: modules, wires: wires)
        let notIDs = order.filter { $0.name == "Not1" }.map(\.umisteni)
        // Each `Not1` reads what its own chain's call is given: the copy under `A1` the wire from `Src`, and the copy under `A2`, whose input
        // is not wired, the constant `true` the call carries (Dirigo writes that constant into the record).
        let wired = notIDs.compactMap { id in resolved.first { $0.inModule == id && $0.inPin == 1 }?.outModule }
        #expect(wired == [1], "only the chain under A1 reads a wire, from Src (module 1): \(wired)")
        let constants = notIDs.compactMap { id -> Int? in
            resolved.contains { $0.inModule == id && $0.inPin == 1 } ? nil : resolvedModules.first { $0.umisteni == id }?.inValues[1]
        }
        #expect(constants == [1], "the chain under A2 reads A2's constant: \(constants)")
    }

    @Test("Compiler and symbol table match macro page names case-insensitively")
    func caseInsensitiveMacroCompilation() throws {
        var project = PCCProject(name: "case-macro")
        project.pages = [ProjectPage(caption: "Main"), ProjectPage(caption: "*MyMacro")]
        project.modules = [
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "Src", x: 0, y: 0, order: 10, threadId: 1, page: "Main",
                      inPins: [], outPins: [Pin(id: 0, value: .bool(true))]),
            PCCModule(id: 2, guid: MacroBlock.guid, name: "Call1", x: 0, y: 0, order: 20, threadId: 1, page: "Main",
                      inPins: [Pin(id: 0, value: .bool(false))], outPins: [Pin(id: 0, value: .bool(false))],
                      rawAttributes: ["MACRO_NAME": "mymacro"]),
            PCCModule(id: 10, guid: InputsBlock.guid, name: "Inputs10", x: 0, y: 0, order: 10, threadId: 0, page: "*MyMacro",
                      inPins: [], outPins: [Pin(id: 0, value: .bool(false))],
                      rawAttributes: ["MACRO_NAME": "Inputs", "KIND": "0"]),
            PCCModule(id: 11, guid: NotBlock.guid, name: "InsideNot", x: 0, y: 0, order: 20, threadId: 0, page: "*MyMacro",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            PCCModule(id: 12, guid: OutputsBlock.guid, name: "Outputs12", x: 0, y: 0, order: 90, threadId: 0, page: "*MyMacro",
                      inPins: [Pin(id: 0, value: .bool(false))], outPins: [],
                      rawAttributes: ["MACRO_NAME": "Outputs", "KIND": "1"]),
        ]
        project.inConnections = [
            Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0, isParam: false),
            Connection(inModuleId: 11, inPinId: 1, outModuleId: 10, outPinId: 0, isParam: false),
            Connection(inModuleId: 12, inPinId: 0, outModuleId: 11, outPinId: 0, isParam: false),
        ]
        let xml = PCCSerializer().serialize(project: project)
        let modules = PLCProjectCompiler.modules(in: xml)
        let wires = PLCProjectCompiler.wires(in: xml)
        #expect(PLCProjectCompiler.programModules(modules).map(\.name).contains("InsideNot"))
        #expect(PLCProjectCompiler.expansionOrder(modules).map(\.name).contains("InsideNot"))

        let classes = SymbolTableGenerationTests.allClasses()
        let symbols = PLCSymbolTable(modules: modules, wires: wires,
                                     classForGUID: classes, shapes: PLCProjectCompiler.classShapes)
        let (_, resolvedWires) = PLCProjectCompiler.expandingMacroInterfaces(modules: modules, wires: wires)
        #expect(resolvedWires.contains { $0.inModule == 11 && $0.inPin == 1 && $0.outModule == 1 && $0.outPin == 0 },
                "expandingMacroInterfaces links case-insensitively across call -> *MyMacro")
        #expect(symbols.addresses[UInt16(2) << 8 | 0] == symbols.addresses[UInt16(11) << 8 | 0],
                "throughMacros aliases macro outputs case-insensitively")
        #expect(PLCProgramOptimizer.cycles(of: [], readers: [:]) == 0)
    }

    @Test("TMDigitalOutputs respects hidden pin mask bits beyond channel 15")
    func digitalOutputsWideMask() throws {
        var mod = PCCModule(
            id: 1,
            guid: BlockTypeCatalog.all.first { $0.blockName == "8xDO" }!.guid,
            name: "DO20", x: 0, y: 0, order: 10, threadId: 1, page: "Main",
            inPins: Array(repeating: Pin(id: 0, value: .bool(true)), count: 21),
            outPins: []
        )
        mod.rawAttributes["PIN_COUNT"] = "20"
        mod.rawAttributes["HIDDEN_PIN_MASK"] = "$\(String(1 << 19, radix: 16, uppercase: true))"
        var project = PCCProject(name: "wide-do")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = [mod]

        let xml = PCCSerializer().serialize(project: project)
        let parsed = PLCProjectCompiler.modules(in: xml)
        let classes = SymbolTableGenerationTests.allClasses()
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes, classForGUID: classes)
        let alloc = PLCSymbolTable(modules: parsed, wires: [], classForGUID: classes,
                                   shapes: PLCProjectCompiler.classShapes)
        let bytes = try compiler.records(modules: parsed, wires: [], allocation: alloc)
        // Header (2 bytes) + 20 channel words (40 bytes) = 42 bytes; channel 19 (last word) is constant 0 (0xC000).
        #expect(bytes.count == 42)
        #expect(bytes[40] == 0x00 && bytes[41] == 0xC0)
    }

    @Test("Macro interface cycles terminate instead of following a fixed hop limit")
    func interfaceCycleTerminates() {
        let interfaceGUID = "3FFBEEC3-FD74-4C54-96F7-864A9D7F5DFC"
        func interface(_ id: UInt8, _ page: String) -> PLCProjectCompiler.Module {
            PLCProjectCompiler.Module(name: "In\(id)", guid: interfaceGUID, umisteni: id, order: 10,
                                      inPinCount: 0, outPinCount: 1, page: page, macroName: "Inputs")
        }
        func call(_ id: UInt8, _ target: String) -> PLCProjectCompiler.Module {
            PLCProjectCompiler.Module(name: "Call\(id)", guid: PLCProjectCompiler.macroCallGUID,
                                      umisteni: id, order: 20, inPinCount: 1, outPinCount: 1,
                                      page: "Main", macroName: target)
        }
        let modules = [interface(10, "*A"), interface(20, "*B"), call(1, "A"), call(2, "B")]
        let wires = [PLCProjectCompiler.Wire(inModule: 2, inPin: 0, outModule: 10, outPin: 0),
                     PLCProjectCompiler.Wire(inModule: 1, inPin: 0, outModule: 20, outPin: 0)]
        let (_, resolved) = PLCProjectCompiler.expandingMacroInterfaces(modules: modules, wires: wires)
        #expect(resolved.count == 2, "the cycle is left as it is instead of dropping or looping")
    }
}
