import Foundation
import WirebenchCore
import WirebenchLibrary

/// A single routed wire as a complete polyline, so `WireLayer` only has to draw it.
public struct RoutedWire: Equatable, Sendable {
    /// Identity of the connection this wire was built from. It travels with the wire and is
    /// unique per connection, so it can identify the drawn shape across updates — a position
    /// in the array would not, and `ForEach` would treat every edit as a whole new set.
    public struct Key: Hashable, Sendable {
        public var outModule: Int
        public var outPin: Int
        public var inModule: Int
        public var inPin: Int
        /// The wire ends on a parameter pin of that module, not an input.
        public var inParam: Bool

        public init(outModule: Int, outPin: Int, inModule: Int, inPin: Int, inParam: Bool = false) {
            self.outModule = outModule; self.outPin = outPin; self.inModule = inModule; self.inPin = inPin; self.inParam = inParam
        }
    }

    public var key: Key
    public var points: [CGPoint]
    public var isHigh: Bool
    public var isFeedback: Bool
    public var width: CGFloat

    public init(key: Key, points: [CGPoint], isHigh: Bool, isFeedback: Bool, width: CGFloat) {
        self.key = key; self.points = points; self.isHigh = isHigh; self.isFeedback = isFeedback; self.width = width
    }

    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.isHigh == rhs.isHigh
            && lhs.isFeedback == rhs.isFeedback && lhs.width == rhs.width
    }
}

/// Where every wire of a page runs: the routing around blocks, the lanes that keep a fan apart, and the caches that
/// keep a wire from moving when nothing near it has. A class because it is a cache; used from the main actor, one
/// per canvas.
@MainActor
public final class WireLayout {
    private let routeCache = WireRouteCache()
    /// The finished geometry of every wire, for as long as nothing that shapes it changes; see `wires`.
    private let geometry = WireGeometryCache()
    private var cachedLaneKey: Int?
    private var cachedLanes: [Int: CableLane] = [:]
    // What the current call was given, which the helpers below read.
    private var selectedPage = ""
    private var snapToGrid = true
    private var dragOffsets: [Int: CGSize] = [:]

    public init() {}

    /// Routes every wire on the page.
    ///
    /// Module and pin lookups go through dictionaries rather than `first(where:)` on the module
    /// array: the previous version was O(connections x modules), ~6,500 comparisons per frame.
    ///
    /// Routing honours the project file. `POINTS` is Dirigo's own route (offsets from the source
    /// pin): a connection with two or more stored points was routed deliberately by the user and is
    /// followed exactly. A single stored point is just the stub Dirigo writes for a freshly drawn
    /// wire, so those are re-routed cleanly instead — which is what removes the long rectangular
    /// detours. Nothing here is ever written back, so the file is untouched either way.
    public func wires(
        project: PCCProject,
        selectedPage: String,
        snapToGrid: Bool,
        pageModuleIds: Set<Int>,
        modulesById: [Int: PCCModule],
        dragOffsets: [Int: CGSize],
        snapshots: [Int: BlockSnapshot]
    ) -> [RoutedWire] {
        self.selectedPage = selectedPage
        self.snapToGrid = snapToGrid
        self.dragOffsets = dragOffsets

        // The wires into inputs and into parameter pins, which Dirigo draws among the inputs.
        let connections = project.paramConnections.isEmpty
            ? project.inConnections
            : (project.inConnections + project.paramConnections)
        let sortedIds = pageModuleIds.sorted()
        let staticKey = staticLayoutKey(sortedIds: sortedIds, modulesById: modulesById, connections: connections)
        routeCache.beginFrame(key: routeKey(staticKey: staticKey), dragging: !dragOffsets.isEmpty)

        var wires: [RoutedWire] = []
        wires.reserveCapacity(connections.count)
        // The cables drawn as the file has them, which are left alone when the page's runs are set apart.
        var followed = Set<RoutedWire.Key>()

        // Every block on the page, so cables can be routed around them rather than through them.
        var obstacles: [Int: CGRect] = [:]
        obstacles.reserveCapacity(sortedIds.count)
        var sortedObstacles: [(id: Int, rect: CGRect)] = []
        sortedObstacles.reserveCapacity(sortedIds.count)
        for id in sortedIds {
            guard let module = modulesById[id] else { continue }
            let drag = dragOffsets[id] ?? .zero
            let rect = CGRect(
                x: module.x + drag.width,
                y: module.y + drag.height,
                width: Double(CardGeometry.cardWidth(for: module)),
                height: Double(CardGeometry.cardHeight(for: module))
            )
            obstacles[id] = rect
            sortedObstacles.append((id: id, rect: rect))
        }

        // Routes come from where the blocks are and how they are wired, never from the simulation, so a tick — which
        // changes only which wires are live — has nothing to re-route. Found the same: reuse the geometry, and read off
        // which wires are live now. (Re-deriving it for every wire at every tick, the held-route checks included, was
        // the larger part of what the canvas itself spent on a tick.)
        let fingerprint = geometryFingerprint(connections: connections, pageModuleIds: pageModuleIds, sortedObstacles: sortedObstacles)
        if let known = geometry.wires(for: fingerprint) {
            return known.map { wire in
                var live = wire
                live.isHigh = snapshots[wire.key.outModule]?.outValues[safe: wire.key.outPin]?.asBool ?? false
                return live
            }.sorted { !$0.isHigh && $1.isHigh }
        }

        let lanesByConnection: [Int: CableLane]
        if cachedLaneKey == staticKey {
            lanesByConnection = cachedLanes
        } else {
            let computed = laneAssignments(connections: connections, pageModuleIds: pageModuleIds, modulesById: modulesById)
            cachedLaneKey = staticKey
            cachedLanes = computed
            lanesByConnection = computed
        }

        for (index, conn) in connections.enumerated() {
            guard pageModuleIds.contains(conn.outModuleId),
                  pageModuleIds.contains(conn.inModuleId),
                  let srcMod = modulesById[conn.outModuleId],
                  let dstMod = modulesById[conn.inModuleId] else { continue }

            let sourceValues = snapshots[srcMod.id]?.outValues
            let isHigh = sourceValues?.indices.contains(conn.outPinId) == true
                ? (sourceValues![conn.outPinId].asBool)
                : false

            let srcDrag = dragOffsets[srcMod.id] ?? .zero
            let dstDrag = dragOffsets[dstMod.id] ?? .zero

            let rawSrc = CardGeometry.outPinPoint(for: srcMod, pinIndex: conn.outPinId)
            let rawDst = conn.isParam ? CardGeometry.paramPinPoint(for: dstMod, pinIndex: conn.inPinId)
                                      : CardGeometry.inPinPoint(for: dstMod, pinIndex: conn.inPinId)
            let src = CGPoint(x: rawSrc.x + srcDrag.width, y: rawSrc.y + srcDrag.height)
            let dst = CGPoint(x: rawDst.x + dstDrag.width, y: rawDst.y + dstDrag.height)

            // Cables leaving the same block are spread across a band, in the order their destinations
            // sit, so parallel runs do not stack into one line and the fan does not braid.
            let cableLane = lanesByConnection[index] ?? CableLane()

            let wireKey = RoutedWire.Key(outModule: conn.outModuleId, outPin: conn.outPinId,
                                         inModule: conn.inModuleId, inPin: conn.inPinId, inParam: conn.isParam)
            if followsStoredRoute(conn, src: src, dst: dst) { followed.insert(wireKey) }
            // A cable the drag does not move holds its route, so dragging one block does not set the
            // whole sheet twitching — but only while that route still clears the blocks being moved.
            // Once one of them is under it, holding would draw a wire through a block, so it re-routes.
            //
            // There is no separate routing for "a drag is in progress": the route is the same function
            // of the same geometry whether or not the mouse is down, so nothing jumps when it is
            // released. It used to run on the fixed shapes for the whole drag and take the searched
            // path on release, which is exactly the jump that was reported.
            let isMoving = dragOffsets[srcMod.id] != nil || dragOffsets[dstMod.id] != nil
            // A cable whose own pins did not move holds the route it was drawn with, for as long as
            // that route still clears every block on the page — through a drag *and* after it, which
            // is what stops the release from changing anything. Recomputing it on release used to give
            // a different path for the same sheet, and the wire jumped. Once a block is under the held
            // route, holding would draw a wire through the block, so it re-routes instead.
            let holdSettled: Bool = {
                guard !isMoving, let held = routeCache.settledPoints(for: wireKey) else { return false }
                return WireRouter.isClear(held, of: sortedObstacles, excluding: conn.outModuleId, and: conn.inModuleId)
            }()
            let points: [CGPoint] = routeCache.points(
                for: wireKey, holdSettled: holdSettled,
                // A cable this drag does not move, re-routed because the drag is over it, is only
                // pushed aside — it must come back when the block moves on, not settle into the
                // detour. Its own pins moving is a real change, so that one is kept.
                temporary: !isMoving && !dragOffsets.isEmpty,
                signature: { routeSignature(conn: conn, src: src, dst: dst, sortedObstacles: sortedObstacles) },
                src: src, dst: dst) {
                routingPoints(conn: conn, src: src, dst: dst,
                              lane: cableLane.offset, legSpread: cableLane.spread,
                              srcMod: srcMod, dstMod: dstMod,
                              srcDrag: srcDrag, dstDrag: dstDrag,
                              obstacles: obstacles, sortedObstacles: sortedObstacles)
            }

            wires.append(RoutedWire(
                key: wireKey,
                points: WireRouter.orthogonalized(points),
                isHigh: isHigh,
                // REVERSE marks a feedback wire in Dirigo; drawn dashed so it reads as one.
                isFeedback: conn.rawAttributes["REVERSE"].map { $0 == "1" || $0.lowercased() == "true" } ?? false,
                width: CGFloat(Double(conn.rawAttributes["WIDTH"] ?? "") ?? 0)
            ))
        }

        wires = separated(wires, followed: followed, sortedObstacles: sortedObstacles)
        geometry.store(wires, for: fingerprint)

        // Draw live wires last so they sit on top of the idle ones.
        return wires.sorted { !$0.isHigh && $1.isHigh }
    }

    /// Cables of different signals that the router left on one line, set side by side (`WireSeparation`). Done on the finished page, because only
    /// there can it be seen which cables share a run; a cable followed from the file as drawn is left as it is.
    private func separated(_ wires: [RoutedWire], followed: Set<RoutedWire.Key>,
                           sortedObstacles: [(id: Int, rect: CGRect)]) -> [RoutedWire] {
        let items = wires.map { wire in
            WireSeparation.Item(net: wire.key.outModule &* 1_000 &+ wire.key.outPin, points: wire.points,
                                movable: !followed.contains(wire.key),
                                from: wire.key.outModule, to: wire.key.inModule)
        }
        let moved = WireSeparation.separate(items, obstacles: sortedObstacles)
        return zip(wires, moved).map { wire, points in
            var copy = wire
            copy.points = points
            return copy
        }
    }

    /// Everything that shapes a wire's route and look, and nothing that a tick changes: which block is where and how
    /// big, what is being dragged, how each connection is wired and drawn.
    private func geometryFingerprint(connections: [Connection], pageModuleIds: Set<Int>,
                                     sortedObstacles: [(id: Int, rect: CGRect)]) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedPage)
        hasher.combine(snapToGrid)
        hasher.combine(CardGeometry.pinPitch)
        hasher.combine(CardGeometry.defaultWidth)
        for (id, rect) in sortedObstacles {
            hasher.combine(id)
            hasher.combine(rect.minX); hasher.combine(rect.minY)
            hasher.combine(rect.width); hasher.combine(rect.height)
        }
        if !dragOffsets.isEmpty {
            for (id, offset) in dragOffsets.sorted(by: { $0.key < $1.key }) {
                hasher.combine(id)
                hasher.combine(offset.width); hasher.combine(offset.height)
            }
        }
        for conn in connections where pageModuleIds.contains(conn.outModuleId)
                                     && pageModuleIds.contains(conn.inModuleId) {
            hasher.combine(conn.outModuleId); hasher.combine(conn.outPinId)
            hasher.combine(conn.inModuleId); hasher.combine(conn.inPinId); hasher.combine(conn.isParam)
            for point in conn.points {
                hasher.combine(point.x); hasher.combine(point.y)
            }
            hasher.combine(conn.rawAttributes["REVERSE"])
            hasher.combine(conn.rawAttributes["WIDTH"])
        }
        return hasher.finalize()
    }

    /// A side-by-side offset for every cable, keyed by connection index.
    ///
    /// Cables leaving one block share the corridor between it and its neighbours, so without an offset
    /// they draw as one line and a fan collapses into a braid. Cables are grouped by the block they
    /// leave, **ordered by where each lands**, and spread by `WireRouter.lanes` — so the fan leaves and
    /// arrives in the same order and does not cross itself more than it must.
    ///
    /// The rule this replaces was `index % 4 * 3`: nine points of variety, reused every four cables, so
    /// anything busier than a handful stacked exactly on top of itself.
    /// How one cable is offset inside its group.
    private struct CableLane {
        /// Shifts the corridor or track, centred on the run (−band/2 … +band/2).
        package var offset: Double = 0
        /// Shifts the detour's legs, 0 for the first cable of the group (0 … band).
        package var spread: Double = 0
    }

    private func laneAssignments(
        connections: [Connection],
        pageModuleIds: Set<Int>,
        modulesById: [Int: PCCModule]
    ) -> [Int: CableLane] {
        var bySource: [Int: [Int]] = [:]
        for (index, conn) in connections.enumerated() {
            guard pageModuleIds.contains(conn.outModuleId),
                  pageModuleIds.contains(conn.inModuleId),
                  modulesById[conn.outModuleId] != nil,
                  modulesById[conn.inModuleId] != nil else { continue }
            bySource[conn.outModuleId, default: []].append(index)
        }

        var lanes: [Int: CableLane] = [:]
        for (_, indices) in bySource {
            let ordered = indices.sorted { first, second in
                let left = connections[first], right = connections[second]
                let leftY = landingY(of: left, modulesById)
                let rightY = landingY(of: right, modulesById)
                if leftY != rightY { return leftY < rightY }
                if left.inModuleId != right.inModuleId { return left.inModuleId < right.inModuleId }
                return left.inPinId < right.inPinId
            }
            let offsets = WireRouter.lanes(forLandings: ordered.map {
                landingY(of: connections[$0], modulesById)
            })
            let step = ordered.count > 1
                ? min(WireRouter.laneSpacing, WireRouter.laneBand / Double(ordered.count - 1))
                : 0
            for (rank, index) in ordered.enumerated() {
                lanes[index] = CableLane(offset: offsets[rank], spread: Double(rank) * step)
            }
        }
        return lanes
    }

    /// The Y of the pin a cable lands on, which is what orders the band.
    private func landingY(of conn: Connection, _ modulesById: [Int: PCCModule]) -> Double {
        guard let module = modulesById[conn.inModuleId] else { return 0 }
        return (conn.isParam ? CardGeometry.paramPinPoint(for: module, pinIndex: conn.inPinId)
                            : CardGeometry.inPinPoint(for: module, pinIndex: conn.inPinId)).y
    }

    /// The path for one cable, computed once per geometry and then cached.
    ///
    /// The two branches are the original rules: a connection with two or more stored `POINTS` was routed
    /// deliberately in Dirigo and is followed exactly, while a single stored point is just the stub
    /// Dirigo writes for a freshly drawn wire and is re-routed cleanly.
    /// Whether a connection's stored `POINTS` are its route. They were drawn relative to the SwiftUI card's pin positions, so
    /// on a card laid out any other way (a roomier pin pitch or width) they no longer meet the pins, and the wire is routed
    /// afresh instead.
    ///
    /// Even then the stored route is only trusted if it lands on the pin it is for: its last point level with the pin and to the left
    /// of it, so that the wire runs into the pin from the side. Some files carry routes whose end is elsewhere (a different card layout
    /// than this one's when they were drawn), and followed anyway such a wire climbs the edge of a block, or stops short under it.
    private func followsStoredRoute(_ conn: Connection, src: CGPoint, dst: CGPoint) -> Bool {
        guard conn.points.count >= 2, CardGeometry.pinPitch == 16, CardGeometry.defaultWidth == 110,
              let last = conn.points.last else { return false }
        return abs(src.y + last.y - dst.y) < 0.5 && src.x + last.x <= dst.x + 0.5
    }

    private func routingPoints(
        conn: Connection,
        src: CGPoint,
        dst: CGPoint,
        lane: Double,
        legSpread: Double,
        srcMod: PCCModule,
        dstMod: PCCModule,
        srcDrag: CGSize,
        dstDrag: CGSize,
        obstacles: [Int: CGRect],
        sortedObstacles: [(id: Int, rect: CGRect)]
    ) -> [CGPoint] {
        if followsStoredRoute(conn, src: src, dst: dst) {
            return [src] + conn.points.map { CGPoint(x: src.x + $0.x, y: src.y + $0.y) } + [dst]
        }
        let srcBottom = srcMod.y + Double(CardGeometry.cardHeight(for: srcMod)) + srcDrag.height
        let dstBottom = dstMod.y + Double(CardGeometry.cardHeight(for: dstMod)) + dstDrag.height
        let srcTop = srcMod.y + srcDrag.height
        let dstTop = dstMod.y + dstDrag.height
        // Route around every block except the two this cable joins.
        var others: [CGRect] = []
        others.reserveCapacity(sortedObstacles.count)
        for (id, rect) in sortedObstacles where id != conn.outModuleId && id != conn.inModuleId {
            others.append(rect)
        }
        var ends: [CGRect] = []
        ends.reserveCapacity(2)
        if let sRect = obstacles[conn.outModuleId] { ends.append(sRect) }
        if let dRect = obstacles[conn.inModuleId], conn.inModuleId != conn.outModuleId { ends.append(dRect) }
        return WireRouter.route(from: src, to: dst, lane: lane, legSpread: legSpread,
                                obstacles: others,
                                clearAbove: min(srcTop, dstTop) - 26,
                                clearBelow: max(srcBottom, dstBottom) + 26,
                                ends: ends)
    }

    /// The cable's geometry, quantised to `WireRouter.pitch`, for the route cache's dead zone.
    ///
    /// While this holds, the cable keeps the interior of its last route and only its ends follow the
    /// pins — so dragging a block a few points moves the wires attached to it at the pins and nowhere
    /// else, instead of swimming the whole run left and right. That steadiness is a *snapped* sheet's
    /// behaviour: with grid snap off the user is placing things by eye, and wires that move in 8 pt
    /// steps read as snapping to a grid they turned off, so the dead zone is off with it.
    /// A connection with stored `POINTS` is followed verbatim and moves with its pins anyway, so it
    /// opts out too.
    private func routeSignature(conn: Connection, src: CGPoint, dst: CGPoint,
                                sortedObstacles: [(id: Int, rect: CGRect)]) -> Int? {
        guard snapToGrid, !followsStoredRoute(conn, src: src, dst: dst) else { return nil }
        func q(_ value: Double) -> Int { Int((value / Double(WireRouter.pitch)).rounded()) }
        var hasher = Hasher()
        hasher.combine(q(src.x)); hasher.combine(q(src.y))
        hasher.combine(q(dst.x)); hasher.combine(q(dst.y))
        for (id, rect) in sortedObstacles where id != conn.outModuleId && id != conn.inModuleId {
            hasher.combine(id)
            hasher.combine(q(rect.minX)); hasher.combine(q(rect.minY))
            hasher.combine(q(rect.maxX)); hasher.combine(q(rect.maxY))
        }
        return hasher.finalize()
    }

    /// Everything routing depends on except active drag offsets.
    private func staticLayoutKey(sortedIds: [Int], modulesById: [Int: PCCModule], connections: [Connection]) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedPage)
        hasher.combine(CardGeometry.pinPitch)
        hasher.combine(CardGeometry.defaultWidth)
        for id in sortedIds {
            guard let module = modulesById[id] else { continue }
            hasher.combine(module.id)
            hasher.combine(module.x)
            hasher.combine(module.y)
            hasher.combine(module.inPins.count)
            hasher.combine(module.paramPins.count)
            hasher.combine(module.outPins.count)
        }
        for conn in connections {
            hasher.combine(conn.outModuleId)
            hasher.combine(conn.outPinId)
            hasher.combine(conn.inModuleId)
            hasher.combine(conn.inPinId)
            hasher.combine(conn.isParam)
            hasher.combine(conn.points.count)
            for point in conn.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
        }
        return hasher.finalize()
    }

    private func routeKey(staticKey: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(staticKey)
        if !dragOffsets.isEmpty {
            for (id, offset) in dragOffsets.sorted(by: { $0.key < $1.key }) {
                hasher.combine(id)
                hasher.combine(offset.width)
                hasher.combine(offset.height)
            }
        }
        return hasher.finalize()
    }
}

/// The wires as last routed, and what they were routed from (`CanvasView.geometryFingerprint`).
final package class WireGeometryCache {
    private var fingerprint: Int?
    private var cached: [RoutedWire] = []

    /// The routed wires, if what shapes them is unchanged since they were stored.
    package func wires(for fingerprint: Int) -> [RoutedWire]? {
        self.fingerprint == fingerprint ? cached : nil
    }

    package func store(_ wires: [RoutedWire], for fingerprint: Int) {
        self.fingerprint = fingerprint
        cached = wires
    }
}

private extension Array {
    /// The element at `index`, or nil beyond either end.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
