import Testing
import Foundation
import WirebenchCore
@testable import WirebenchModel

@Suite("Wire router optimization invariants")
struct WireRouterOptimizationTests {
    private static func isOrthogonal(_ points: [CGPoint]) -> Bool {
        guard points.count >= 2 else { return true }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if a.x != b.x && a.y != b.y { return false }
        }
        return true
    }

    @Test("Crowded A* corridor search finds an orthogonal, obstacle-free route")
    func aStarCorridorSearch() {
        let obstacles: [CGRect] = [
            CGRect(x: 220, y: 10, width: 120, height: 185),
            CGRect(x: 220, y: 215, width: 120, height: 260),
            CGRect(x: 370, y: 10, width: 120, height: 165),
            CGRect(x: 370, y: 195, width: 120, height: 280),
        ]
        let ends = [
            CGRect(x: 40, y: 120, width: 110, height: 80),
            CGRect(x: 540, y: 220, width: 110, height: 80),
        ]
        let src = CGPoint(x: 150, y: 160)
        let dst = CGPoint(x: 540, y: 260)

        let path = WireRouter.route(
            from: src, to: dst, lane: 0, legSpread: 0,
            obstacles: obstacles, clearAbove: 40, clearBelow: 420, ends: ends
        )

        #expect(path.first == src)
        #expect(path.last == dst)
        #expect(path.count >= 6)
        #expect(Self.isOrthogonal(path))
        #expect(WireRouter.isClear(path, of: obstacles + ends))
    }

    @Test("Zero-alloc isClear excluding endpoints matches filtered obstacle checks")
    func isClearExcludingEndpoints() {
        let obstacles: [(id: Int, rect: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 100, height: 80)),
            (2, CGRect(x: 300, y: 0, width: 100, height: 80)),
            (3, CGRect(x: 150, y: 20, width: 60, height: 60)),
        ]
        let crossingPath = [
            CGPoint(x: 80, y: 40),
            CGPoint(x: 320, y: 40),
        ]
        #expect(!WireRouter.isClear(crossingPath, of: obstacles, excluding: 1, and: 2))

        let clearPath = [
            CGPoint(x: 100, y: 40),
            CGPoint(x: 120, y: 40),
            CGPoint(x: 120, y: 100),
            CGPoint(x: 260, y: 100),
            CGPoint(x: 260, y: 40),
            CGPoint(x: 300, y: 40),
        ]
        #expect(WireRouter.isClear(clearPath, of: obstacles, excluding: 1, and: 2))
    }

    @Test("WireSeparation separates overlapping nets and rolls back clusters that would hit obstacles")
    func separationAndRollback() {
        let pathA = [CGPoint(x: 100, y: 40), CGPoint(x: 200, y: 40), CGPoint(x: 200, y: 140), CGPoint(x: 300, y: 140)]
        let pathB = [CGPoint(x: 100, y: 60), CGPoint(x: 200, y: 60), CGPoint(x: 200, y: 160), CGPoint(x: 300, y: 160)]
        let itemA = WireSeparation.Item(net: 1, points: pathA, movable: true, from: 1, to: 2)
        let itemB = WireSeparation.Item(net: 2, points: pathB, movable: true, from: 3, to: 4)
        let pathC = [CGPoint(x: 100, y: 300), CGPoint(x: 150, y: 300), CGPoint(x: 150, y: 340), CGPoint(x: 300, y: 340)]
        let itemC = WireSeparation.Item(net: 5, points: pathC, movable: true, from: 5, to: 6)

        let separated = WireSeparation.separate([itemA, itemB, itemC], obstacles: [])
        #expect(separated[0][1].x != separated[1][1].x)
        #expect(separated[2] == pathC)

        // Obstacles immediately on both sides of x = 200 (gap of 4pt) prevent separation without crossing.
        let tightObstacles: [(id: Int, rect: CGRect)] = [
            (99, CGRect(x: 170, y: 20, width: 28, height: 180)),
            (100, CGRect(x: 202, y: 20, width: 28, height: 180)),
        ]
        let rolledBack = WireSeparation.separate([itemA, itemB], obstacles: tightObstacles)
        #expect(rolledBack[0] == pathA)
        #expect(rolledBack[1] == pathB)
    }

    @Test("Temporary detours during drag are cached per pitch step and snap back to settled path when clear")
    @MainActor
    func temporaryDragCacheAndSnapBack() {
        var project = PCCProject(name: "drag-cache")
        project.pages = [ProjectPage(caption: "Main")]
        let m1 = PCCModule(id: 1, guid: UUID(), name: "Src", x: 40, y: 100, order: 10, threadId: 1, page: "Main",
                           inPins: [], outPins: [Pin(id: 0, value: .int32(0))])
        let m2 = PCCModule(id: 2, guid: UUID(), name: "Dst", x: 400, y: 140, order: 20, threadId: 1, page: "Main",
                           inPins: [Pin(id: 0, value: .int32(0))], outPins: [])
        let m3 = PCCModule(id: 3, guid: UUID(), name: "Mover", x: 210, y: 320, order: 30, threadId: 1, page: "Main",
                           inPins: [], outPins: [])
        project.modules = [m1, m2, m3]
        _ = project.connect(outModuleId: 1, outPinId: 0, toModuleId: 2, inPinId: 0)

        let pageIds = Set(project.modules.map(\.id))
        let byId = Dictionary(uniqueKeysWithValues: project.modules.map { ($0.id, $0) })
        let layout = WireLayout()

        // 1. Settled initial route with m3 out of the way.
        let initial = layout.wires(project: project, selectedPage: "Main", snapToGrid: true,
                                   pageModuleIds: pageIds, modulesById: byId, dragOffsets: [:], snapshots: [:])
        #expect(initial.count == 1)
        let settledPoints = initial[0].points

        // 2. Drag m3 directly onto the wire's path -> wire must detour temporarily.
        let overA = layout.wires(project: project, selectedPage: "Main", snapToGrid: true,
                                 pageModuleIds: pageIds, modulesById: byId,
                                 dragOffsets: [3: CGSize(width: 0, height: -200)], snapshots: [:])
        let detourPoints = overA[0].points
        #expect(detourPoints != settledPoints)

        // 3. Sub-pitch micro-drag within the same 8pt grid cell keeps the cached temporary detour.
        let overB = layout.wires(project: project, selectedPage: "Main", snapToGrid: true,
                                 pageModuleIds: pageIds, modulesById: byId,
                                 dragOffsets: [3: CGSize(width: 1, height: -201)], snapshots: [:])
        #expect(overB[0].points == detourPoints)

        // 4. Drag m3 clear again -> stationary wire snaps back to its settled path (not stuck in detour).
        let cleared = layout.wires(project: project, selectedPage: "Main", snapToGrid: true,
                                   pageModuleIds: pageIds, modulesById: byId,
                                   dragOffsets: [3: CGSize(width: 0, height: 100)], snapshots: [:])
        #expect(cleared[0].points == settledPoints)
    }
}
