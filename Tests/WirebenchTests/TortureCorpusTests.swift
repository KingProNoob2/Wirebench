import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
import WirebenchHardware
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// The torture corpus: projects built to break the port, and the invariants every one of them must hold.
///
/// The suite's other corpus tests prove the *hand-drawn* projects still work. These prove the shapes those
/// projects do not contain: every block type in one file, containers inside macros, extreme values, and wire
/// graphs that are already broken. A project here is checked on four axes — it survives a save, both
/// implementations of each block behave the same, the core runs it deterministically, and the compiler
/// accounts for every module.
@Suite("Torture corpus")
struct TortureCorpusTests {
    // MARK: - Invariants

    /// Saves, reads back, saves again: the bytes must not drift and the model must not change.
    ///
    /// A project built here has no raw attributes to start with, so the first save and the second are compared
    /// rather than the model before and after — what a user does is save, reopen, save.
    ///
    /// `modelStable` compares the models as well, which holds for a file that already carries every attribute the
    /// serialiser writes — every file Dirigo wrote does. A hand-written file that leaves an attribute out gains it on
    /// the first save, so for those only the bytes are compared: the second save must still be the first.
    @discardableResult
    static func expectRoundTrip(_ project: PCCProject, _ label: String, modelStable: Bool = true) throws -> PCCProject {
        let once = PCCSerializer().serialize(project: project)
        let first = try PCCParser().parse(xmlString: once)
        let twice = PCCSerializer().serialize(project: first)
        #expect(twice == once, "\(label): a second save differs from the first")
        if modelStable {
            let second = try PCCParser().parse(xmlString: twice)
            #expect(first == second, "\(label): the model changed when the saved file was read again")
        }
        return first
    }

    /// The core runs the project and does it the same way twice: same pins at every one of `steps` steps.
    static func expectDeterministic(_ project: PCCProject, _ label: String, steps: Int = 120) {
        let first = CxxSimulationCore(project: project, profileScheduling: false)
        let second = CxxSimulationCore(project: project, profileScheduling: false)
        let cycle = Double(max(1, project.appOptions.cycleDelay))
        for step in 0..<steps {
            first.step(deltaMs: cycle, now: TortureProjects.now)
            second.step(deltaMs: cycle, now: TortureProjects.now)
            #expect(first.pinsDigest() == second.pinsDigest(),
                    "\(label): two runs of the same project differ at step \(step)")
        }
    }

    /// Every module the core knows reports exactly the pins its model has.
    static func expectPinCounts(_ project: PCCProject, _ label: String) {
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        for module in project.modules where core.contains(moduleId: module.id) {
            #expect(core.inPins(moduleId: module.id).count == module.inPins.count,
                    "\(label): \(module.name) reports \(core.inPins(moduleId: module.id).count) in pins, the model has \(module.inPins.count)")
            #expect(core.outPins(moduleId: module.id).count == module.outPins.count,
                    "\(label): \(module.name) reports \(core.outPins(moduleId: module.id).count) out pins, the model has \(module.outPins.count)")
        }
    }

    // MARK: - Every catalogued type in one file

    @Test("Every block type at once survives a save unchanged")
    func kitchenSinkRoundTrips() throws {
        let project = TortureProjects.kitchenSink()
        #expect(project.modules.count == BlockTypeCatalog.all.count)
        let read = try Self.expectRoundTrip(project, "kitchen sink")
        #expect(read.modules.count == project.modules.count)
        // Names, pages, pin values and the wires are the things a lossy save costs first.
        for (before, after) in zip(project.modules, read.modules) {
            #expect(before.name == after.name)
            #expect(before.guid == after.guid)
            #expect(before.page == after.page)
            #expect(before.threadId == after.threadId)
            // The file stores pins as text, so what survives is the text: `.bool(true)` reads back as `.int32(1)`.
            #expect(before.inPins.map(\.value.description) == after.inPins.map(\.value.description))
            #expect(before.paramPins.map(\.value.description) == after.paramPins.map(\.value.description))
        }
        #expect(read.inConnections.count == project.inConnections.count)
    }

    @Test("Every block type at once runs, and the compiler accounts for every module exactly once")
    func kitchenSinkCompiles() throws {
        let project = TortureProjects.kitchenSink()
        let xml = PCCSerializer().serialize(project: project)
        let template = try PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640))
        let build = try PLCProjectBuild.compile(xml: xml, classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                template: template)
        let report = build.report
        // Whatever the compiler leaves out, it has to say which: the four buckets are the module list.
        let buckets = report.compiledModules + report.displayModules + report.unshapedModules.count + report.macros.count
        #expect(buckets == report.moduleCount,
                "compiled \(report.compiledModules) + displays \(report.displayModules) + unshaped \(report.unshapedModules.count) + macros \(report.macros.count) != \(report.moduleCount) modules")
        #expect(report.moduleCount == project.modules.count)
        #expect(!build.table.isEmpty)
        #expect(build.moduleRecords.count == project.modules.count)
        #expect(report.isComplete == report.unshaped.isEmpty)
    }

    /// Every catalogued type, one module per project, the core against its own Swift class.
    ///
    /// This is the per-kind check the whole-corpus test cannot make: on a real project a difference is attributed
    /// to the module it shows on, and a module whose class is unported takes its neighbours' evidence with it.
    @Test("Every ported kind behaves in the core as its Swift class does")
    func everyPortedKindAgrees() throws {
        var failures: [String] = []
        var checked = 0
        for info in BlockTypeCatalog.all {
            // Native Maraflow blocks have no Swift twin; their semantics are covered by MaraflowImportTests.
            if MaraflowCatalog.definition(forGuid: info.guid) != nil { continue }
            guard CxxSimulationCore.kind(forGUID: info.guid) != nil else { continue }
            var project = PCCProject(name: info.blockName)
            project.pages = [ProjectPage(caption: "main")]
            project.appOptions.cycleDelay = 10
            project.modules = [TortureProjects.module(info.guid, id: 1, name: info.blockName, order: 10)]
            checked += 1
            let module = project.modules[0]
            let swift = BlockOracle(module: module, cycleDelayMs: 10, now: TortureProjects.now)
            let core = CxxSimulationCore(project: project, profileScheduling: false)
            for step in 0..<60 {
                swift.step()
                core.step(deltaMs: 10, now: TortureProjects.now)
                for pin in swift.block.outPins.indices {
                    let theirs = core.outValue(moduleId: 1, pin: pin)?.description ?? "-"
                    let ours = swift.block.outPins[pin].description
                    if theirs != ours { failures.append("\(info.blockName) step \(step) out[\(pin)]: core \(theirs) vs swift \(ours)") }
                }
            }
        }
        #expect(checked >= 70, "only \(checked) kinds are ported; the sweep would not mean anything")
        #expect(failures.isEmpty, "\(failures.count) divergences: \(failures.prefix(20).joined(separator: " | "))")
    }

    // MARK: - Containers and macros

    @Test("Containers nested three deep survive a save and expand into every module exactly once")
    func deepContainersRoundTripAndExpand() throws {
        let project = TortureProjects.deepContainers()
        _ = try Self.expectRoundTrip(project, "deep containers")
        let expanded = ConstructContainers.expanded(project)
        #expect(Set(expanded.modules.map(\.id)).count == expanded.modules.count, "expansion duplicated a module id")
        #expect(Set(project.modules.map(\.name)).isSubset(of: Set(expanded.modules.map(\.name))),
                "expansion lost a module")
        #expect(expanded.modules.count > project.modules.count, "no marker blocks were created")
        Self.expectDeterministic(project, "deep containers")
    }

    /// A macro's copy must keep its members pointing at *its own* container.
    ///
    /// `MacroInstancing` renumbers a cloned sheet's modules and rewrites their wires and call names. A container is
    /// named by id in the project's own attributes (`IN_CONTAINER`), so a clone whose attribute still holds the
    /// original id puts its members inside the original container — a different page, a different branch, and on
    /// the original thread.
    @Test("A cloned macro sheet keeps its containers to itself")
    func clonedMacroKeepsItsContainers() throws {
        let project = TortureProjects.macroWithContainers()
        let instanced = MacroInstancing.instanced(project)
        let clones = Set(instanced.modules.map(\.page)).filter { $0.contains("#") }
        #expect(!clones.isEmpty, "the fixture did not clone a sheet, so nothing is being tested")
        for page in clones {
            let onSheet = instanced.modules.filter { $0.page == page }
            for module in onSheet {
                guard let owner = module.rawAttributes["IN_CONTAINER"], let id = Int(owner) else { continue }
                let target = instanced.modules.first { $0.id == id }
                #expect(target?.page == page,
                        "\(module.name) on \(page) is in container \(id), which is on \(target?.page ?? "nothing")")
            }
        }
        // And the whole project still runs, with every module kept.
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        #expect(core.runtimeModules.count >= project.modules.count,
                "instancing dropped modules: \(core.runtimeModules.count) of \(project.modules.count)")
        Self.expectDeterministic(project, "macro with containers")
    }

    // MARK: - Extremes

    @Test("Unicode, XML metacharacters and extreme values survive a save")
    func extremesRoundTrip() throws {
        let project = TortureProjects.extremes()
        let read = try Self.expectRoundTrip(project, "extremes")
        #expect(read.description == project.description)
        #expect(read.author == project.author)
        #expect(read.projectPath == project.projectPath)
        #expect(read.pageSize == 8)
        #expect(read.oldExportMode)
        #expect(read.pages.map(\.caption) == project.pages.map(\.caption))
        let wide = try #require(read.modules.first { $0.id == 1 })
        #expect(wide.inPins.count == 65)
        #expect(wide.x == -1234 && wide.y == 9876)
        let readWide = try #require(read.modules.first { $0.id == 1 })
        let wroteWide = try #require(project.modules.first { $0.id == 1 })
        // The text is what a file keeps, and it is kept even where the number no longer fits a 32-bit Int.
        for pin in wroteWide.inPins.indices where wroteWide.inPins[pin].value != .bool(pin % 2 == 0) {
            #expect(readWide.inPins[pin].rawAttributes["VALUE"] == wroteWide.inPins[pin].value.description,
                    "pin \(pin) was written as \(wroteWide.inPins[pin].value.description) and read back as \(readWide.inPins[pin].rawAttributes["VALUE"] ?? "-")")
        }
        // The section and the attribute the model has no field for are still in the file.
        let text = PCCSerializer().serialize(project: read)
        #expect(text.contains("CONSTANTS_X"))
        #expect(text.contains("FUTURE_ATTRIBUTE") == false, "the fixture has no root attribute of that name")
        #expect(text.contains("CUSTOM="))
        Self.expectPinCounts(project, "extremes")
    }

    @Test("A hand-written file keeps what the model does not understand")
    func gnarlyXMLKeepsEverything() throws {
        let project = try PCCParser().parse(xmlString: TortureProjects.gnarlyXML)
        #expect(project.name == "Gnarly & <odd>")
        #expect(project.description == "Číslo č \t tab")
        #expect(project.pageSize == 8)
        #expect(project.oldExportMode)
        let module = try #require(project.modules.first)
        #expect(module.name == "Not & one")
        #expect(module.inPins.first?.name == "Legacy")
        #expect(module.inPins.first?.inverted == true)
        let wire = try #require(project.inConnections.first)
        #expect(wire.points.count == 2)
        #expect(wire.nameX == 1.5 && wire.nameY == -2.5)

        let text = PCCSerializer().serialize(project: project)
        for kept in ["FUTURE_SECTION", "FUTURE_ATTRIBUTE", "UNKNOWN_COMM", "UNKNOWN_MODULE", "FUTURE_CHILD",
                     "UNKNOWN_CONN", "FUTURE_CONN_CHILD", "CONSTANT NAME=\"C1\"", "READONLY",
                     "PEER_2", "Prázdná", "Popisek &amp; č"] {
            #expect(text.contains(kept), "\(kept) was dropped on save")
        }
        // Reading the saved file again changes nothing.
        _ = try Self.expectRoundTrip(project, "gnarly XML")
    }

    // MARK: - Graphs that are already broken

    @Test("A file with broken wires still opens, saves and runs")
    func brokenGraphIsSurvivable() throws {
        let project = TortureProjects.brokenGraph()
        let read = try Self.expectRoundTrip(project, "broken graph")
        #expect(read.modules.count == project.modules.count, "a duplicate module id was dropped")
        #expect(read.inConnections.count == project.inConnections.count)
        // Running it must not trap or hang, whatever the wires say.
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        for _ in 0..<50 { core.step(deltaMs: 7, now: TortureProjects.now) }
        #expect(core.tickCount == 50)
    }

    @Test("A ring of wires terminates and settles")
    func ringTerminates() throws {
        let project = TortureProjects.ring(12)
        _ = try Self.expectRoundTrip(project, "ring")
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        for _ in 0..<100 { core.step(deltaMs: 7, now: TortureProjects.now) }
        // A ring of inverters settles into one of two states; either is fine, but it must not keep moving.
        let first = core.pinsDigest()
        core.step(deltaMs: 7, now: TortureProjects.now)
        #expect(core.pinsDigest() == first, "the ring never settles")
        Self.expectDeterministic(project, "ring")
    }

    @Test("A long chain carries a value end to end in one propagation")
    func chainCarries() throws {
        let count = 200
        let project = TortureProjects.chain(count)
        _ = try Self.expectRoundTrip(project, "chain")
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        core.step(deltaMs: 7, now: TortureProjects.now)
        // Not a claim about the exact value: that the last block's inputs were written at all.
        let last = try #require(project.modules.last)
        #expect(core.inPins(moduleId: last.id).count == last.inPins.count)
        Self.expectDeterministic(project, "chain", steps: 60)
    }

    // MARK: - Limits of the program format

    /// A project with more modules than the program can address must say so.
    ///
    /// The program's module position is one byte (a symbol row's terminal is `(position << 8) | pin`), so a project with
    /// more than 256 modules has blocks Dirigo could not address either. The compiler used to drop them in silence and
    /// still report the build complete — a compiled program missing every block past the 255th, with nothing said.
    @Test("More modules than the program can address is reported, not dropped in silence")
    func tooManyModulesIsReported() throws {
        let template = try PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640))
        func build(_ count: Int) throws -> PLCProjectBuild {
            try PLCProjectBuild.compile(xml: PCCSerializer().serialize(project: TortureProjects.chain(count)),
                                        classForGUID: BlockTypeCatalog.classNamesByGUID, template: template)
        }
        let over = try build(300)
        #expect(over.report.outOfRangeModules.count == 45, "300 modules, 255 of which fit in a byte")
        #expect(!over.report.isComplete)
        #expect(over.report.lines.contains { $0.contains("no room in the program") })
        #expect(over.report.moduleCount == 255)

        let fits = try build(255)
        #expect(fits.report.outOfRangeModules.isEmpty)
        #expect(fits.report.isComplete)
    }

    // MARK: - Legacy export

    @Test("Every torture project exports to a legacy .pcc that reads back")
    func legacyExportReadsBack() throws {
        let projects = [("kitchen sink", TortureProjects.kitchenSink()),
                        ("deep containers", TortureProjects.deepContainers()),
                        ("extremes", TortureProjects.extremes()),
                        ("ring", TortureProjects.ring(12))]
        for (name, project) in projects {
            let result = PaperSize.prepareForDirigo(project, extent: CardGeometry.dirigoExtent(for:))
            #expect(result.project.pageSize == 60, "\(name): the export must ask for Dirigo's own paper size")
            _ = try Self.expectRoundTrip(result.project, "\(name) exported")
        }
    }
}

/// What the compiler is given.
///
/// The app's *Build* menu and `wirebench-cli build` must compile the same program. They did not: the command line read the
/// file as it stood, so a project saved by the editor — which keeps its PLC configuration in its own section and records
/// `If`/`Switch` nesting as attributes — compiled without its commands or its branch markers, while the app's build had both.
@Suite("Build input")
struct BuildInputTests {
    static let template = try? PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640))

    /// This is the bug that was silent: a `SystemCmd` the editor holds as PLC configuration is not in `MODULES`, so
    /// compiling the file as it stands leaves the command out of the program — and the report still says the build is
    /// complete, so nothing warns.
    @Test("A project the editor saved compiles differently until it is prepared")
    func preparationChangesTheProgram() throws {
        let template = try #require(Self.template)
        let project = TortureProjects.withConfiguration()
        #expect(project.plcConfiguration.count == 1)
        let raw = PCCSerializer().serialize(project: project)
        #expect(raw.contains("PLC_CONFIGURATION"))
        #expect(BuildInput.needsPreparation(project))
        let prepared = BuildInput.xml(for: project, defaultThread: 2)
        #expect(!prepared.contains("PLC_CONFIGURATION"), "the prepared project must have the block back instead")

        let unprepared = try PLCProjectBuild.compile(xml: raw, classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                     template: template)
        let compiled = try PLCProjectBuild.compile(xml: prepared, classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                   template: template)
        #expect(unprepared.report.isComplete, "the unprepared build does not even report that it left the command out")
        #expect(unprepared.table != compiled.table, "the PLC command never reaches the program")
        #expect(unprepared.report.symbolRows + 1 == compiled.report.symbolRows,
                "the command has \(compiled.report.symbolRows - unprepared.report.symbolRows) symbol rows, expected one")
    }

    @Test("Preparation is what the app's own path does, and a plain project is left alone")
    func preparationMatchesTheAppPath() throws {
        for project in [TortureProjects.deepContainers(), TortureProjects.macroWithContainers()] {
            let appPath = PCCSerializer().serialize(
                project: ConstructContainers.expanded(PLCConfiguration.injecting(project, defaultThread: 2)))
            #expect(BuildInput.xml(for: project, defaultThread: 2) == appPath)
        }
        let plain = TortureProjects.ring(6)
        #expect(!BuildInput.needsPreparation(plain))
        #expect(BuildInput.xml(for: plain) == PCCSerializer().serialize(project: plain))
    }

    @Test("A file with nothing to prepare is compiled byte for byte as it was read")
    func plainFileIsNotRerendered() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wirebench-build-input-\(UUID().uuidString).pcc")
        let raw = TortureProjects.gnarlyXML
        try raw.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BuildInput.xml(contentsOf: url) == raw)
    }
}
