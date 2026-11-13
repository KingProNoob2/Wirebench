import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// The Qt frontend gets Maraflow's graphics and ST/LD page through the scene, and never sees the hidden runtime module
/// as a block.
@Suite("Maraflow Qt scene")
struct MaraflowQtSceneTests {
    @MainActor
    @Test("A pure ST page becomes page info, not a fake block")
    func pureSTScene() throws {
        let code = "VAR n : INT; END_VAR n := n + 1;"
        let entries: [(String, String)] = [
            ("project.name", "PureST"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main_ST"),
            ("page.0.language", "ST"),
            ("page.0.stCode", code),
            ("page.0.stThreadId", "2"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scene-st-\(UUID()).mfl")
        try MaraflowImportTests.propertiesXML(entries).write(to: url)
        let model = AppModel()
        model.loadProject(url: url)
        let scene = SceneSnapshot.make(of: model, layout: WireLayout())
        #expect(scene.modules.isEmpty)
        #expect(scene.pagesInfo.first?.count == 0)
        #expect(scene.maraflowPage?.kind == "Structured Text")
        #expect(scene.maraflowPage?.code.contains("n := n + 1") == true)
    }

    @MainActor
    @Test("Maraflow graphics reach the scene with their signed geometry")
    func graphicScene() throws {
        let entries: [(String, String)] = [
            ("project.name", "Graphics"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.0.graphicCount", "1"),
            ("page.0.graphic.0.kind", "RECTANGLE"),
            ("page.0.graphic.0.gridX", "72"),
            ("page.0.graphic.0.gridY", "2"),
            ("page.0.graphic.0.gridW", "-70"),
            ("page.0.graphic.0.gridH", "14"),
            ("page.0.graphic.0.filled", "true"),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scene-graphics-\(UUID()).mfl")
        try MaraflowImportTests.propertiesXML(entries).write(to: url)
        let model = AppModel()
        model.loadProject(url: url)
        let scene = SceneSnapshot.make(of: model, layout: WireLayout())
        let graphic = try #require(scene.maraflowGraphics.first)
        #expect(graphic.kind == "RECTANGLE")
        #expect(graphic.x == 64)
        #expect(graphic.w == 2240)
        #expect(graphic.filled)
        #expect(scene.maraflowPage == nil)
    }
}
