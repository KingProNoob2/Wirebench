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

/// The editor's own model, on the projects built to break the engine.
///
/// The engine tests prove the core reads a file; this proves the *editor* survives one — that it can open it, select
/// every block, step the simulation, take an edit back and write the document out unchanged. A model that keys state by
/// module id is where a duplicate id or a pin count nobody expected shows up.
@Suite("Editor on the torture corpus")
@MainActor
struct EditorTortureTests {
    static func projects() -> [(String, PCCProject)] {
        [("kitchen sink", TortureProjects.kitchenSink()),
         ("deep containers", TortureProjects.deepContainers()),
         ("macro containers", TortureProjects.macroWithContainers()),
         ("extremes", TortureProjects.extremes()),
         ("broken graph", TortureProjects.brokenGraph()),
         ("ring", TortureProjects.ring(12)),
         ("configuration", TortureProjects.withConfiguration())]
    }

    static func temporary(_ name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wirebench-torture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    @Test("Every torture project opens, selects, steps, undoes and saves unchanged")
    func opensEditsAndSaves() throws {
        for (name, project) in Self.projects() {
            let input = Self.temporary("in.pcc")
            try PCCSerializer().serialize(project: project).write(to: input, atomically: true, encoding: .utf8)

            let model = AppModel()
            model.loadProject(url: input)
            let loaded = try #require(model.project, "\(name): the editor did not open the project")

            // Every block can be selected; the canvas draws the selection.
            for module in loaded.modules { model.selectedModuleId = module.id }
            model.selectedModuleId = nil

            // Two steps through the editor's own loop, which mirrors the core into the blocks the views draw.
            model.step()
            model.step()

            // An edit and its undo: the document must come back exactly as it was.
            let before = model.project
            if let editable = loaded.modules.first(where: { !$0.inPins.isEmpty }) {
                model.setModuleInput(moduleId: editable.id, pinIndex: 0, value: .bool(true))
                model.undo()
                #expect(model.project == before, "\(name): undo did not restore the project")
            }

            // Saving must write what is open, not something the model made up on the way out.
            var written = try #require(model.project)
            let output = Self.temporary("out.wbp")
            written.projectPath = output.path
            try model.saveProject(to: output)
            let saved = try WirebenchDocument.decode(Data(contentsOf: output))
            #expect(saved == written, "\(name): the saved file is not what the editor holds")
        }
    }

    @Test("A block whose id repeats can still be selected and deleted without taking the model with it")
    func duplicateIdsAreSurvivable() throws {
        let input = Self.temporary("dup.pcc")
        try PCCSerializer().serialize(project: TortureProjects.brokenGraph())
            .write(to: input, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: input)
        let loaded = try #require(model.project)
        #expect(loaded.modules.filter { $0.id == 1 }.count == 2, "the fixture lost its duplicate id")

        model.selectedModuleId = 1
        model.deleteSelectedModule()
        model.undo()
        #expect(model.project?.modules.filter { $0.id == 1 }.count == 2, "undo did not bring the duplicate back")
    }
}

/// The editor's Build, which is where the two front ends meet the compiler.
@Suite("Editor build")
@MainActor
struct EditorBuildTests {
    /// A command added in *PLC Configuration* has no page and thread 0 until something builds it; the app's build gives
    /// it both, so the command reaches the program. (The command line did not, until `BuildInput` — see `BuildInputTests`.)
    @Test("The app's Build puts a configuration-only command into the program, and reports it complete")
    func configurationReachesTheProgram() throws {
        let input = EditorTortureTests.temporary("config.pcc")
        try PCCSerializer().serialize(project: TortureProjects.withConfiguration())
            .write(to: input, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: input)
        let report = try #require(model.compileProject(), "the editor refused to build a project it opened")
        #expect(report.moduleCount == 5, "the command is a module of the program")
        #expect(report.symbolRows > 0)
        #expect(report.unshapedModules.isEmpty, "a ring of Not blocks has every shape it needs")
        #expect(!report.programBinary.isEmpty)
        // And the built table is a table the upload path can read back.
        let table = try PLCProgramTable(bytes: report.table)
        #expect(table.checksumIsValid)
    }
}
