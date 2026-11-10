import Testing
import Foundation
import WirebenchCore
@testable import WirebenchModel

/// *Export Legacy .PCC* writes a copy the original Dirigo opens. Dirigo's sheet is fixed (A3) and its blocks are a fixed size, so a roomy layout
/// has to be squashed onto it: the distances shrink, the blocks do not.
@Suite("Legacy .pcc export")
@MainActor
struct LegacyExportTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/kostka-1.pcc")

    private func loaded() throws -> PCCProject {
        let model = AppModel()
        model.loadProject(url: Self.fixture)
        return try #require(model.project)
    }

    /// Whether every block, at its position and Dirigo's size, is inside the sheet's margins.
    private func onSheet(_ project: PCCProject) -> Bool {
        let sheet = PaperSize.sheet(forPageSize: 60)
        return project.modules.allSatisfy { module in
            let size = CardGeometry.dirigoExtent(for: module)
            return module.x >= PaperSize.exportMargin - 0.001 && module.y >= PaperSize.exportMargin - 0.001
                && module.x + size.width <= sheet.width - PaperSize.exportMargin + 0.001
                && module.y + size.height <= sheet.height - PaperSize.exportMargin + 0.001
        }
    }

    @Test("A layout too big for the sheet is squashed so that every block, at Dirigo's own size, is on it")
    func oversizedLayoutFits() throws {
        var project = try loaded()
        for i in project.modules.indices { project.modules[i].x *= 6; project.modules[i].y *= 6 }
        #expect(!onSheet(project))

        let result = PaperSize.prepareForDirigo(project, extent: CardGeometry.dirigoExtent(for:))
        #expect(onSheet(result.project), "blocks hang over the sheet after the squash")
        #expect(result.project.pageSize == 60)
        #expect(result.adjustments.contains { $0.contains("scaled") })
        // The arrangement is kept: blocks stay in the same left-to-right and top-to-bottom order.
        let before = project.modules.sorted { $0.id < $1.id }, after = result.project.modules.sorted { $0.id < $1.id }
        for (a, b) in zip(before, after) {
            for (c, d) in zip(before, after) {
                #expect((a.x < c.x) == (b.x < d.x) || a.x == c.x)
            }
            if a.id > 3 { break }
        }
    }

    @Test("A block the editor draws taller than the old 200 pt bound is still on the sheet: a 26-pin ISwitch is not hidden by a nominal size")
    func tallBlocksAreCounted() throws {
        var project = try loaded()
        let tall = try #require(project.modules.max { CardGeometry.dirigoExtent(for: $0).height < CardGeometry.dirigoExtent(for: $1).height })
        #expect(CardGeometry.dirigoExtent(for: tall).height > 200)
        // The block that reaches furthest down sits near the bottom of a layout that is too big.
        for i in project.modules.indices { project.modules[i].y *= 8 }
        let result = PaperSize.prepareForDirigo(project, extent: CardGeometry.dirigoExtent(for:))
        #expect(onSheet(result.project))
    }

    @Test("A layout that already fits is left exactly as it is, and the scale reaches the parameter wires as well as the input wires")
    func fittingLayoutIsUntouchedAndRoutesScale() throws {
        let project = try loaded()
        let same = PaperSize.prepareForDirigo(project, extent: CardGeometry.dirigoExtent(for:))
        #expect(same.adjustments.isEmpty && same.project.modules.map(\.x) == project.modules.map(\.x))

        var big = project
        for i in big.modules.indices { big.modules[i].x *= 6; big.modules[i].y *= 6 }
        for i in big.paramConnections.indices { big.paramConnections[i].points = [RoutePoint(x: 600, y: 120)] }
        for i in big.inConnections.indices { big.inConnections[i].points = [RoutePoint(x: 600, y: 120)] }
        let result = PaperSize.prepareForDirigo(big, extent: CardGeometry.dirigoExtent(for:))
        let scale = try #require(result.project.inConnections.first?.points.first?.x) / 600
        #expect(scale < 1 && scale > 0)
        let params = try #require(result.project.paramConnections.first?.points.first)
        #expect(abs(params.x - 600 * scale) < 0.001 && abs(params.y - 120 * scale) < 0.001, "parameter wires scale with the layout")
    }

    @Test("The exported file reopens with every block and wire, inside the sheet")
    func writtenFileReopens() throws {
        let model = AppModel()
        model.loadProject(url: Self.fixture)
        for i in (model.project?.modules.indices ?? 0..<0) { model.project?.modules[i].x *= 6; model.project?.modules[i].y *= 6 }
        let original = try #require(model.project)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-export-\(UUID().uuidString).pcc")
        defer { try? FileManager.default.removeItem(at: url) }
        model.exportForDirigo()
        model.finishExport(to: url)

        let reread = try PCCParser().parse(fileAt: url)
        #expect(reread.modules.count == original.modules.count + original.plcConfiguration.count, "the PLC configuration comes back as blocks")
        #expect(reread.inConnections.count == original.inConnections.count)
        #expect(reread.paramConnections.count == original.paramConnections.count)
        #expect(reread.pageSize == 60)
        #expect(onSheet(reread))
        // The open project is untouched: a copy was written, not the document.
        #expect(model.project?.modules.map(\.x) == original.modules.map(\.x))
    }
}
