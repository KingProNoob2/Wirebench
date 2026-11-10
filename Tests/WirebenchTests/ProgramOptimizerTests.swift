import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchHardware

/// The optimising pass: dataflow order, dead gates, and that without it nothing changes.
@Suite("Program optimiser")
struct ProgramOptimizerTests {
    static let valueGUID = UUID(uuidString: "112B3FE6-C440-4463-80EF-FDD1F6F74F56")!

    /// A source feeding three `Not`s written in the *wrong* order (the last link first), a display on the last, and
    /// a fourth `Not` that nothing reads.
    static func project() -> PCCProject {
        var project = PCCProject(name: "optimise")
        project.pages = [ProjectPage(caption: "main")]
        func not(_ id: Int, _ name: String, order: Int) -> PCCModule {
            PCCModule(id: id, guid: NotBlock.guid, name: name, x: 0, y: 0, order: order, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))])
        }
        project.modules = [
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "Src", x: 0, y: 0, order: 5, threadId: 1, page: "main",
                      inPins: [], outPins: [Pin(id: 0, value: .bool(false))]),
            not(2, "NotC", order: 10),         // reads NotB — written first
            not(3, "NotB", order: 20),         // reads NotA
            not(4, "NotA", order: 30),         // reads Src — written last
            not(5, "NotD", order: 40),         // reads Src; nobody reads NotD
            PCCModule(id: 6, guid: valueGUID, name: "Value1", x: 0, y: 0, order: 50, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(false))], outPins: []),
        ]
        func wire(_ from: Int, _ to: Int, pin: Int = 1) -> Connection {
            Connection(inModuleId: to, inPinId: pin, outModuleId: from, outPinId: 0)
        }
        project.inConnections = [wire(1, 4), wire(4, 3), wire(3, 2), wire(2, 6, pin: 0), wire(1, 5)]
        return project
    }

    static func build(optimize: Bool) throws -> PLCProjectBuild {
        try PLCProjectBuild.compile(xml: PCCSerializer().serialize(project: project()),
                                    classForGUID: BlockTypeCatalog.classNamesByGUID,
                                    template: try #require(PLCProgramTable.buildTemplate()), optimize: optimize)
    }

    @Test("Records come out in dataflow order and the unread gate is dropped")
    func orderAndDeadCode() throws {
        let plain = try Self.build(optimize: false)
        let fast = try Self.build(optimize: true)
        let result = try #require(fast.report.optimization)
        #expect(result.removedModules == ["NotD"])
        #expect(result.cyclesBefore == 3 && result.cyclesAfter == 1, "\(result)")
        #expect(result.bytesSaved > 0 && fast.records.count == plain.records.count - result.bytesSaved)
        #expect(plain.report.optimization == nil, "a build that does not ask is untouched")
    }

    @Test("What is optimised still allocates the same addresses")
    func allocationUnchanged() throws {
        #expect(try Self.build(optimize: false).symbolCSV == Self.build(optimize: true).symbolCSV)
    }

    @Test("Optimising twice changes nothing the second time")
    func idempotent() throws {
        let xml = PCCSerializer().serialize(project: Self.project())
        let modules = PLCProjectCompiler.modules(in: xml)
        let wires = PLCProjectCompiler.wires(in: xml)
        let classes = Dictionary(uniqueKeysWithValues: BlockTypeCatalog.classNamesByGUID.map {
            (PLCProjectCompiler.normaliseGUID($0.key), $0.value) })
        let first = PLCProgramOptimizer.optimize(PLCProjectCompiler.recordOrder(modules), wires: wires,
                                                 allModules: modules, classForGUID: classes)
        let second = PLCProgramOptimizer.optimize(first.modules, wires: wires, allModules: modules, classForGUID: classes)
        #expect(second.moved == 0 && second.removed.isEmpty && second.modules == first.modules)
    }

    static func guid(_ blockName: String) -> UUID {
        BlockTypeCatalog.all.first { $0.blockName == blockName }!.guid
    }

    /// `Src` feeds an `IAdd` that a display reads, a `FAdd` that nothing reads, and — through a `Not` — an
    /// `IAdd` whose `En` is a constant `en`, also read by the display.
    static func mathProject(en: Bool, enWired: Bool = false) -> PCCProject {
        var project = PCCProject(name: "math")
        project.pages = [ProjectPage(caption: "main")]
        func block(_ id: Int, _ kind: String, order: Int, en: Bool = true) -> PCCModule {
            PCCModule(id: id, guid: guid(kind), name: "\(kind)\(id)", x: 0, y: 0, order: order, threadId: 1,
                      page: "main",
                      inPins: [Pin(id: 0, value: .bool(en)), Pin(id: 1, value: .int32(0)), Pin(id: 2, value: .int32(0))],
                      outPins: [Pin(id: 0, value: .int32(0))])
        }
        project.modules = [
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "Src", x: 0, y: 0, order: 5, threadId: 1, page: "main",
                      inPins: [], outPins: [Pin(id: 0, value: .bool(false))]),
            block(2, "IAdd", order: 10),
            block(3, "FAdd", order: 20),
            PCCModule(id: 4, guid: NotBlock.guid, name: "Not4", x: 0, y: 0, order: 30, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            block(5, "IAdd", order: 40, en: en),
            PCCModule(id: 6, guid: valueGUID, name: "Value1", x: 0, y: 0, order: 50, threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .int32(0)), Pin(id: 1, value: .int32(0))], outPins: []),
        ]
        func wire(_ from: Int, _ to: Int, pin: Int) -> Connection {
            Connection(inModuleId: to, inPinId: pin, outModuleId: from, outPinId: 0)
        }
        project.inConnections = [wire(1, 2, pin: 1), wire(1, 3, pin: 1), wire(1, 4, pin: 1), wire(4, 5, pin: 1),
                                 wire(2, 6, pin: 0), wire(5, 6, pin: 1)]
        if enWired { project.inConnections.append(wire(1, 5, pin: 0)) }
        return project
    }

    static func build(_ project: PCCProject, optimize: Bool) throws -> PLCProjectBuild {
        try PLCProjectBuild.compile(xml: PCCSerializer().serialize(project: project),
                                    classForGUID: BlockTypeCatalog.classNamesByGUID,
                                    template: try #require(PLCProgramTable.buildTemplate()), optimize: optimize)
    }

    @Test("Unread arithmetic is dropped like an unread gate")
    func unreadMathDropped() throws {
        let fast = try Self.build(Self.mathProject(en: true), optimize: true)
        let removed = try #require(fast.report.optimization).removedModules
        #expect(removed == ["FAdd3"])
    }

    @Test("A pure block switched off by a constant En = 0 is dropped, and so is what only it read")
    func switchedOffDropped() throws {
        let project = Self.mathProject(en: false)
        let plain = try Self.build(project, optimize: false)
        let fast = try Self.build(project, optimize: true)
        let result = try #require(fast.report.optimization)
        #expect(Set(result.removedModules) == ["FAdd3", "IAdd5", "Not4"])
        #expect(result.bytesSaved > 0 && fast.records.count == plain.records.count - result.bytesSaved)
        // Its readers still find its output where it always was.
        #expect(plain.symbolCSV == fast.symbolCSV)
    }

    @Test("A block whose En is wired is never taken for switched off, whatever its constant says")
    func wiredEnKept() throws {
        let fast = try Self.build(Self.mathProject(en: false, enWired: true), optimize: true)
        let removed = try #require(fast.report.optimization).removedModules
        #expect(removed == ["FAdd3"])
    }
}

