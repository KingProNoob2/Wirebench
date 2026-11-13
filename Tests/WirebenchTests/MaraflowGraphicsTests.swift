import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// Maraflow graphics keep their own signed geometry, kinds and bindings; they are no longer flattened to Dirigo shapes.
@Suite("Maraflow graphics")
struct MaraflowGraphicsTests {
    @Test("Signed boxes, zero-height lines and indicator bindings survive the import")
    func typedGraphics() throws {
        var entries: [(String, String)] = [
            ("project.name", "Graphics"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "1"),
            ("page.0.wireCount", "0"),
            ("page.0.graphicCount", "3"),
            ("page.0.graphic.0.kind", "RECTANGLE"),
            ("page.0.graphic.0.gridX", "72"),
            ("page.0.graphic.0.gridY", "2"),
            ("page.0.graphic.0.gridW", "-70"),
            ("page.0.graphic.0.gridH", "14"),
            ("page.0.graphic.0.text", "Label"),
            ("page.0.graphic.1.kind", "LINE"),
            ("page.0.graphic.1.gridX", "2"),
            ("page.0.graphic.1.gridY", "9"),
            ("page.0.graphic.1.gridW", "70"),
            ("page.0.graphic.1.gridH", "0"),
            ("page.0.graphic.2.kind", "CIRCLE"),
            ("page.0.graphic.2.gridX", "69"),
            ("page.0.graphic.2.gridY", "3"),
            ("page.0.graphic.2.gridW", "2"),
            ("page.0.graphic.2.gridH", "2"),
            ("page.0.graphic.2.indicatorEnabled", "true"),
            ("page.0.graphic.2.indicatorPin", "RightRed.Y"),
            ("page.0.graphic.2.indicatorActiveColor", "-1754827"),
            ("page.0.graphic.2.indicatorInactiveColor", "-985864"),
        ]
        entries += Self.block("page.0.block.0.", id: "not", definition: "Bool.Not", type: "Not",
                              name: "RightRed", gridX: 10, gridY: 10, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("X", "Input", "BOOL", "0")],
                              outputs: [("Y", "Output", "BOOL", "0")])
        let imported = try MaraflowImporter.importProject(data: Self.props(entries), filename: "graphics")
        let graphics = try #require(imported.project.maraflow?.graphics)
        #expect(graphics.count == 3)
        #expect(graphics[0].gridW == -70)
        #expect(graphics[1].gridH == 0)
        #expect(graphics[2].indicatorEnabled)
        #expect(graphics[2].indicatorPin == "RightRed.Y")
        #expect(imported.project.graphics.isEmpty, "Maraflow graphics are drawn natively, not as Dirigo shapes")
    }

    @MainActor
    @Test("Visual buttons and indicators resolve to the block's pins")
    func bindings() throws {
        var entries: [(String, String)] = [
            ("project.name", "Bindings"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "1"),
            ("page.0.wireCount", "0"),
            ("page.0.graphicCount", "1"),
            ("page.0.graphic.0.kind", "VISUAL_BUTTON"),
            ("page.0.graphic.0.gridX", "2"),
            ("page.0.graphic.0.gridY", "2"),
            ("page.0.graphic.0.gridW", "5"),
            ("page.0.graphic.0.gridH", "2"),
            ("page.0.graphic.0.text", "IZS"),
            ("page.0.graphic.0.boundTargetPin", "RightRed.X"),
        ]
        entries += Self.block("page.0.block.0.", id: "not", definition: "Bool.Not", type: "Not",
                              name: "RightRed", gridX: 10, gridY: 10, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("X", "Input", "BOOL", "0")],
                              outputs: [("Y", "Output", "BOOL", "0")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bindings-\(UUID()).mfl")
        try Self.props(entries).write(to: url)
        let model = AppModel()
        model.loadProject(url: url)
        if let module = model.project?.modules.first(where: { $0.name == "RightRed" }) {
            print("PINS", module.inPins.map { ($0.name ?? "nil", ModulePinCatalog.inputPinLabel(for: module, index: module.inPins.firstIndex(of: $0) ?? 0)) })
        } else { print("NO MODULE", model.project?.modules.map(\.name) ?? []) }
        let input = try #require(model.maraflowBinding("RightRed.X", output: false))
        #expect(input.pinIndex == 1)
        #expect(model.maraflowBinding("RightRed.Y", output: true)?.pinIndex == 0)
        #expect(!model.maraflowBooleanValue("RightRed.Y"))
        model.pressMaraflowBinding("RightRed.X")
        #expect(model.project?.modules.first { $0.name == "RightRed" }?.inPins[1].value.asBool == true)
    }

    private static func props(_ entries: [(String, String)]) -> Data {
        MaraflowImportTests.propertiesXML(entries)
    }

    private static func block(_ prefix: String, id: String, definition: String, type: String, name: String,
                              gridX: Int, gridY: Int, order: Int,
                              inputs: [(String, String, String, String)],
                              outputs: [(String, String, String, String)]) -> [(String, String)] {
        MaraflowImportTests.block(prefix, id: id, definition: definition, type: type, name: name,
                                  gridX: gridX, gridY: gridY, order: order,
                                  inputs: inputs, outputs: outputs)
    }
}
