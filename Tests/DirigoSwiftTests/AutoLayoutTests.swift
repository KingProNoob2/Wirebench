import Testing
import Foundation
import CoreGraphics
@testable import DirigoCore
@testable import DirigoApp

/// *Organize Blocks*: columns by signal flow, aligned pins, nothing overlapping.
@Suite("Organize blocks")
struct AutoLayoutTests {
    static let size = CGSize(width: 110, height: 60)

    static func node(_ id: Int, order: Int? = nil) -> AutoLayout.Node {
        AutoLayout.Node(id: id, size: size, order: order ?? id)
    }

    static func overlaps(_ placed: [Int: CGPoint], sizes: [Int: CGSize]) -> Bool {
        let rects = placed.map { CGRect(origin: $0.value, size: sizes[$0.key] ?? size) }
        for i in rects.indices { for j in rects.indices where j > i && rects[i].intersects(rects[j]) { return true } }
        return false
    }

    @Test("A chain written backwards still runs left to right, each pin level with the one feeding it")
    func chain() {
        let nodes = [Self.node(1, order: 30), Self.node(2, order: 20), Self.node(3, order: 10)]
        let edges = [AutoLayout.Edge(from: 1, to: 2, fromPinY: 40, toPinY: 40),
                     AutoLayout.Edge(from: 2, to: 3, fromPinY: 40, toPinY: 56)]
        let placed = AutoLayout.positions(nodes: nodes, edges: edges, origin: CGPoint(x: 100, y: 50))
        #expect(placed[1]!.x < placed[2]!.x && placed[2]!.x < placed[3]!.x)
        #expect(placed[2]!.y + 40 == placed[1]!.y + 40)
        #expect(placed[3]!.y + 56 == placed[2]!.y + 40)
        // The page's top-left stays put.
        #expect(placed.values.map(\.x).min() == 100 && placed.values.map(\.y).min() == 50)
    }

    @Test("A constant sits next to the block it feeds, not at the far left")
    func sourceMovesRight() {
        let nodes = (1...4).map { Self.node($0) }
        let edges = [AutoLayout.Edge(from: 1, to: 2), AutoLayout.Edge(from: 2, to: 3), AutoLayout.Edge(from: 4, to: 3)]
        let placed = AutoLayout.positions(nodes: nodes, edges: edges, origin: .zero)
        #expect(placed[4]!.x == placed[2]!.x)
    }

    @Test("Loops, fan-out and unwired blocks: everything is placed and nothing overlaps")
    func noOverlaps() {
        let nodes = (1...12).map { Self.node($0) }
        var edges = [AutoLayout.Edge(from: 1, to: 2), AutoLayout.Edge(from: 2, to: 3),
                     AutoLayout.Edge(from: 3, to: 2),                       // loop
                     AutoLayout.Edge(from: 1, to: 4), AutoLayout.Edge(from: 1, to: 5),
                     AutoLayout.Edge(from: 5, to: 6), AutoLayout.Edge(from: 4, to: 6)]
        edges += [AutoLayout.Edge(from: 7, to: 8), AutoLayout.Edge(from: 8, to: 7)]   // a loop with no way in
        let placed = AutoLayout.positions(nodes: nodes, edges: edges, origin: .zero)
        #expect(placed.count == 12)
        #expect(!Self.overlaps(placed, sizes: [:]))
        // Unwired blocks (9…12) go below everything wired.
        let wiredBottom = (1...8).map { placed[$0]!.y + Self.size.height }.max()!
        #expect((9...12).allSatisfy { placed[$0]!.y > wiredBottom })
    }

    @Test("Organizing a real page moves only that page, in one undo step, with nothing overlapping")
    @MainActor
    func realProject() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rulkoshaddirigo.pcc")
        guard let project = try? PCCParser().parse(fileAt: url) else { return }
        let model = AppModel()
        model.project = project
        let page = "*rultea"
        model.selectedPage = page
        model.organizeBlocks()
        let after = try #require(model.project)
        let others = { (p: PCCProject) in p.modules.filter { $0.page != page }.map { [$0.x, $0.y] } }
        #expect(others(after) == others(project))
        let onPage = after.modules.filter { $0.page == page }
        let placed = Dictionary(uniqueKeysWithValues: onPage.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        let sizes = Dictionary(uniqueKeysWithValues: onPage.map {
            ($0.id, CGSize(width: ModuleCardView.cardWidth(for: $0), height: ModuleCardView.cardHeight(for: $0))) })
        #expect(!Self.overlaps(placed, sizes: sizes))
        model.undo()
        #expect(model.project == project)
    }
}
