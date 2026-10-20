import CoreGraphics
import Foundation

/// Orthogonal routing for cables on the schematic.
///
/// Dirigo stores a wire's route as `POINTS` — offsets from the source pin, editable through its
/// *Add point* / *Default points* / *Delete point* commands. A connection with two or more stored
/// points was routed deliberately and is followed exactly. A single stored point is just the stub
/// Dirigo writes for a freshly drawn wire; those are routed here.
///
/// The router is **obstacle-aware**. The obvious implementation — turn at the midpoint between the
/// two pins — puts the corridor inside whatever block happens to sit between them, so cables cut
/// straight through blocks. Instead the corridor is searched for in the gap between the two pins,
/// and only a corridor that clears every block is used. When no such simple shape exists — a block
/// sits on one of the horizontal runs, or a detour's vertical leg — the cable is routed by a search
/// over the free channels between blocks instead (`searchRoute`).
///
/// Nothing here is written back to the project.
public enum WireRouter {
    /// Distance a cable runs straight out of a pin before turning.
    public static let stub: CGFloat = 18
    /// Clearance kept between a cable and a block it routes past.
    public static let clearance: CGFloat = 10

    private static let forwardThreshold: CGFloat = 14

    /// Routes between two pin positions, avoiding `obstacles` (block rectangles).
    ///
    /// - Parameters:
    ///   - lane: a small offset applied to the chosen corridor so cables sharing a run sit side by
    ///     side instead of stacking into one line.
    ///   - obstacles: rectangles to route around. Normally every block on the page except the two
    ///     being connected.
    ///   - clearAbove: a Y coordinate above both connected blocks. The detour may not cross it.
    ///   - clearBelow: the same below.
    ///   - ends: the two connected blocks. A cable may leave and enter them through their pins, but
    ///     must not cut across them anywhere else.
    ///   - searching: false keeps to the fixed shapes. The search can pick a quite different path for
    ///     a slightly different layout, so while a block is being dragged it would make cables jump
    ///     from frame to frame.
    public static func route(
        from src: CGPoint,
        to dst: CGPoint,
        lane: Double = 0,
        obstacles: [CGRect] = [],
        clearAbove: Double? = nil,
        clearBelow: Double = 0,
        ends: [CGRect] = [],
        searching: Bool = true
    ) -> [CGPoint] {
        let simple = simpleRoute(from: src, to: dst, lane: lane, obstacles: obstacles,
                                 clearAbove: clearAbove, clearBelow: clearBelow)
        let blocked = crossings(simple, obstacles: obstacles, ends: ends)
        guard searching, blocked > 0,
              let searched = searchRoute(from: src, to: dst, lane: lane, obstacles: obstacles, ends: ends),
              // Where blocks overlap there may be no clean way at all; a detour that crosses as much
              // as the simple shape only adds length.
              crossings(searched, obstacles: obstacles, ends: ends) < blocked
        else { return simple }
        return searched
    }

    /// The fixed shapes: one turn in the gap, a jog between neighbours, or a detour above or below.
    private static func simpleRoute(
        from src: CGPoint,
        to dst: CGPoint,
        lane: Double,
        obstacles: [CGRect],
        clearAbove: Double?,
        clearBelow: Double
    ) -> [CGPoint] {
        let gap = dst.x - src.x

        // Comfortable gap: stub out of the source, turn once in the gap, stub into the target.
        if gap > 2 * stub + forwardThreshold {
            let a = CGPoint(x: src.x + stub, y: src.y)
            let b = CGPoint(x: dst.x - stub, y: dst.y)
            let corridor = forwardCorridor(from: a, to: b, lane: lane, obstacles: obstacles)
            return [src, a, CGPoint(x: corridor, y: a.y), CGPoint(x: corridor, y: b.y), b, dst]
        }

        // Neighbouring blocks: there is no room for two stubs, so make a single jog between the
        // pins. Testing the *stub* positions here instead was a bug — a gap narrower than two stubs
        // flipped the cable into the backward branch and drew a pointless loop beside the block.
        if gap > 0 {
            let midX = (src.x + dst.x) / 2 + CGFloat(lane)
            return [src, CGPoint(x: midX, y: src.y), CGPoint(x: midX, y: dst.y), dst]
        }

        // Overlapping or running backwards: get clear vertically, then come back in from the left.
        let a = CGPoint(x: src.x + stub, y: src.y)
        let b = CGPoint(x: dst.x - stub, y: dst.y)
        // The connected blocks are not in `obstacles`, so their own extent has to be respected
        // explicitly — otherwise a detour can clip the block it belongs to.
        let top = min(CGFloat(clearAbove ?? (min(a.y, b.y) - 60)), min(a.y, b.y) - 60)
        let bottom = max(CGFloat(clearBelow), max(src.y, dst.y) + 60)
        let track = detourTrack(from: a, to: b, below: bottom, above: top, lane: lane,
                                obstacles: obstacles)
        return [src, a, CGPoint(x: a.x, y: track), CGPoint(x: b.x, y: track), b, dst]
    }

    /// Picks the X for a forward cable's single vertical run.
    ///
    /// Searches outward from the midpoint so the turn stays near the middle of the run when the way
    /// is clear, and slides into a genuine gap when it is not.
    private static func forwardCorridor(
        from a: CGPoint,
        to b: CGPoint,
        lane: Double,
        obstacles: [CGRect]
    ) -> CGFloat {
        let mid = (a.x + b.x) / 2
        let low = a.x + 4
        let high = b.x - 4
        guard high > low else { return mid + CGFloat(lane) }

        let top = min(a.y, b.y)
        let bottom = max(a.y, b.y)

        for step in stride(from: 0.0, through: Double(high - low), by: 6.0) {
            for candidate in (step == 0 ? [mid] : [mid - CGFloat(step), mid + CGFloat(step)]) {
                guard candidate >= low, candidate <= high else { continue }
                if !Self.blocksVertically(x: candidate, top: top, bottom: bottom, obstacles: obstacles) {
                    return candidate + CGFloat(lane)
                }
            }
        }
        return mid + CGFloat(lane)
    }

    /// Picks a track above or below the cable's span, preferring the nearer and clearer side.
    private static func detourTrack(
        from a: CGPoint,
        to b: CGPoint,
        below: CGFloat,
        above: CGFloat,
        lane: Double,
        obstacles: [CGRect]
    ) -> CGFloat {
        let span = (min(a.x, b.x)...max(a.x, b.x))
        var floor = below
        var ceiling = above
        for rect in obstacles where rect.maxX > span.lowerBound && rect.minX < span.upperBound {
            floor = max(floor, rect.maxY + clearance)
            ceiling = min(ceiling, rect.minY - clearance)
        }
        // Whichever side needs the smaller detour from the pins themselves.
        let pinTop = min(a.y, b.y)
        let pinBottom = max(a.y, b.y)
        let downCost = floor - pinBottom
        let upCost = pinTop - ceiling
        let chosen = upCost >= 0 && (downCost < 0 || upCost < downCost) ? ceiling : floor
        return chosen + CGFloat(lane)
    }

    /// True when a vertical segment at `x` spanning `top...bottom` would cross a block.
    private static func blocksVertically(
        x: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        obstacles: [CGRect]
    ) -> Bool {
        for rect in obstacles {
            let padded = rect.insetBy(dx: -clearance, dy: -clearance)
            if x >= padded.minX && x <= padded.maxX && bottom >= padded.minY && top <= padded.maxY {
                return true
            }
        }
        return false
    }

    /// How many times the route crosses a block: other blocks with `clearance` to spare, the
    /// connected blocks merely entered (the stubs run right up to their edges).
    static func crossings(_ points: [CGPoint], obstacles: [CGRect], ends: [CGRect]) -> Int {
        guard points.count >= 2 else { return 0 }
        let rects = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) } + ends
        var count = 0
        for i in 1..<points.count {
            count += rects.filter { crosses(points[i - 1], points[i], $0) }.count
        }
        return count
    }

    /// True when the axis-aligned segment `p`–`q` passes through the inside of `rect`. Running along
    /// its border does not count.
    private static func crosses(_ p: CGPoint, _ q: CGPoint, _ rect: CGRect) -> Bool {
        min(p.x, q.x) < rect.maxX && max(p.x, q.x) > rect.minX
            && min(p.y, q.y) < rect.maxY && max(p.y, q.y) > rect.minY
            && (p.x == q.x ? (p.x > rect.minX && p.x < rect.maxX) : (p.y > rect.minY && p.y < rect.maxY))
    }

    /// Bends cost as much as this much extra cable, so the search prefers a slightly longer run with
    /// fewer corners — a staircase of short jogs reads worse than a detour.
    private static let bendCost: CGFloat = 40

    /// Routes through the channels between blocks: a cheapest-path search over a sparse grid whose
    /// lines are the blocks' clearance edges and the centres of the gaps between them.
    ///
    /// Returns nil when there is no way through, so the caller can fall back to a fixed shape.
    static func searchRoute(
        from src: CGPoint,
        to dst: CGPoint,
        lane: Double,
        obstacles: [CGRect],
        ends: [CGRect]
    ) -> [CGPoint]? {
        let a = CGPoint(x: src.x + stub, y: src.y)
        let b = CGPoint(x: dst.x - stub, y: dst.y)
        // Where blocks sit closer than the clearance, a pin's stub can start inside a neighbour's
        // margin; that neighbour then only blocks its own body, or the cable could never get out.
        let all = (obstacles + ends).compactMap { rect -> CGRect? in
            let padded = rect.insetBy(dx: -clearance, dy: -clearance)
            guard padded.contains(a) || padded.contains(b) else { return padded }
            return rect.contains(a) || rect.contains(b) ? nil : rect
        }

        // Search near the two pins first; only a cable boxed in there needs the whole page.
        let near = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -240, dy: -240)
        if let found = search(a: a, b: b, rects: all.filter { $0.intersects(near) }, within: near) {
            return finish(found, src: src, dst: dst, lane: lane)
        }
        let page = all.reduce(near) { $0.union($1) }.insetBy(dx: -2 * clearance, dy: -2 * clearance)
        return search(a: a, b: b, rects: all, within: page).map { finish($0, src: src, dst: dst, lane: lane) }
    }

    /// Adds the pins back on, drops points in the middle of straight runs, and shifts the inner
    /// runs onto `lane` — the stubs stay on the pins' own lines.
    private static func finish(_ path: [CGPoint], src: CGPoint, dst: CGPoint, lane: Double) -> [CGPoint] {
        var points: [CGPoint] = []
        for point in [src] + path + [dst] {
            if let last = points.last, last == point { continue }
            if points.count >= 2 {
                let p = points[points.count - 2], q = points[points.count - 1]
                if (p.x == q.x && q.x == point.x) || (p.y == q.y && q.y == point.y) { points.removeLast() }
            }
            points.append(point)
        }
        guard lane != 0, points.count > 3 else { return points }
        var shifted = points
        for k in 1..<(points.count - 2) {
            let p = points[k], q = points[k + 1]
            if p.x == q.x {
                shifted[k].x += CGFloat(lane); shifted[k + 1].x += CGFloat(lane)
            } else {
                shifted[k].y += CGFloat(lane); shifted[k + 1].y += CGFloat(lane)
            }
        }
        return shifted
    }

    /// A* over grid nodes × heading. A cable leaves `a` heading right and must arrive at `b`
    /// heading right; it may not double back on itself.
    private static func search(a: CGPoint, b: CGPoint, rects: [CGRect], within area: CGRect) -> [CGPoint]? {
        // Grid lines: the pins, the clearance edges, and the middle of every gap between edges.
        func lines(_ fixed: [CGFloat], _ edges: [CGFloat], _ low: CGFloat, _ high: CGFloat) -> [CGFloat] {
            let sorted = Array(Set(edges.filter { $0 >= low && $0 <= high } + [low, high])).sorted()
            let middles = zip(sorted, sorted.dropFirst()).map { ($0 + $1) / 2 }
            return Array(Set(fixed + sorted + middles)).sorted()
        }
        let xs = lines([a.x, b.x], rects.flatMap { [$0.minX, $0.maxX] }, area.minX, area.maxX)
        let ys = lines([a.y, b.y], rects.flatMap { [$0.minY, $0.maxY] }, area.minY, area.maxY)
        guard let ax = xs.firstIndex(of: a.x), let ay = ys.firstIndex(of: a.y),
              let bx = xs.firstIndex(of: b.x), let by = ys.firstIndex(of: b.y) else { return nil }

        let nx = xs.count, ny = ys.count
        // East, south, west, north.
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        func state(_ i: Int, _ j: Int, _ d: Int) -> Int { (j * nx + i) * 4 + d }

        // A run hugging a block costs a little more, so cables take the middle of a channel.
        // Each grid edge is looked at from both ends and in several headings, so it is worked out once.
        // Index: the edge leaving node (i, j) eastwards (0) or southwards (1); nan means blocked.
        var edgeCache = [CGFloat](repeating: -1, count: nx * ny * 2)
        func edgeCost(_ i: Int, _ j: Int, _ ni: Int, _ nj: Int) -> CGFloat? {
            let (ei, ej) = (min(i, ni), min(j, nj))
            let key = (ej * nx + ei) * 2 + (nj != j ? 1 : 0)
            if edgeCache[key] < 0 {
                edgeCache[key] = measure(CGPoint(x: xs[i], y: ys[j]), CGPoint(x: xs[ni], y: ys[nj])) ?? .nan
            }
            return edgeCache[key].isNaN ? nil : edgeCache[key]
        }
        func measure(_ p: CGPoint, _ q: CGPoint) -> CGFloat? {
            var hugs = false
            for rect in rects {
                if crosses(p, q, rect) { return nil }
                if !hugs, crosses(p, q, rect.insetBy(dx: -clearance, dy: -clearance)) { hugs = true }
            }
            let length = abs(q.x - p.x) + abs(q.y - p.y)
            return hugs ? length * 1.5 : length
        }

        var cost = [CGFloat](repeating: .infinity, count: nx * ny * 4)
        var previous = [Int](repeating: -1, count: nx * ny * 4)
        var heap = MinHeap()
        let start = state(ax, ay, 0)
        cost[start] = 0
        // Remaining distance to `b`: never more than the true cost, so the first arrival is the best.
        func estimate(_ i: Int, _ j: Int) -> CGFloat { abs(xs[i] - b.x) + abs(ys[j] - b.y) }
        heap.push(estimate(ax, ay), start)

        while let (_, s) = heap.pop() {
            let c = cost[s]
            let d = s % 4, cell = s / 4, i = cell % nx, j = cell / nx
            if i == bx && j == by && d == 0 {
                var path: [CGPoint] = []
                var t = s
                while t >= 0 {
                    let tc = t / 4
                    path.append(CGPoint(x: xs[tc % nx], y: ys[tc / nx]))
                    t = previous[t]
                }
                return path.reversed()
            }
            for (nd, step) in steps.enumerated() where nd != (d + 2) % 4 {
                let ni = i + step.0, nj = j + step.1
                guard ni >= 0, ni < nx, nj >= 0, nj < ny,
                      let length = edgeCost(i, j, ni, nj)
                else { continue }
                let next = state(ni, nj, nd)
                let total = c + length + (nd == d ? 0 : bendCost)
                if total < cost[next] {
                    cost[next] = total
                    previous[next] = s
                    heap.push(total + estimate(ni, nj), next)
                }
            }
        }
        return nil
    }

    /// A binary min-heap of (cost, state) pairs — just enough for the search above.
    private struct MinHeap {
        private var items: [(CGFloat, Int)] = []

        mutating func push(_ cost: CGFloat, _ state: Int) {
            items.append((cost, state))
            var i = items.count - 1
            while i > 0, items[(i - 1) / 2].0 > items[i].0 {
                items.swapAt(i, (i - 1) / 2)
                i = (i - 1) / 2
            }
        }

        mutating func pop() -> (CGFloat, Int)? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].0 < items[m].0 { m = l }
                if r < items.count, items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
            return top
        }
    }

    /// Replaces each sharp corner of a routed polyline with a short quadratic arc.
    ///
    /// Right angles on their own read as a tangle; rounding them is most of what makes a dense
    /// schematic legible.
    public static func roundedPath(_ points: [CGPoint], radius: CGFloat = 7) -> CGPath {
        let path = CGMutablePath()
        // A point in the middle of a straight run (the stub end, where a cable leaves its pin) is no
        // corner, but it splits the run — and a corner's radius is capped by half its neighbouring
        // segments, so it would round one corner tighter than the others. Drop such points first.
        var points = points
        var k = 1
        while k < points.count - 1 {
            let p = points[k - 1], q = points[k], r = points[k + 1]
            let straight = (p.x == q.x && q.x == r.x) || (p.y == q.y && q.y == r.y)
            let between = (min(p.x, r.x)...max(p.x, r.x)).contains(q.x) && (min(p.y, r.y)...max(p.y, r.y)).contains(q.y)
            if straight && between { points.remove(at: k) } else { k += 1 }
        }
        guard points.count >= 2 else { return path }

        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let previous = points[i - 1]
            let corner = points[i]
            let next = points[i + 1]

            let inLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outLength = hypot(next.x - corner.x, next.y - corner.y)
            let r = min(radius, inLength / 2, outLength / 2)

            guard r > 0.5, inLength > 0, outLength > 0 else {
                path.addLine(to: corner)
                continue
            }

            let before = CGPoint(
                x: corner.x - (corner.x - previous.x) / inLength * r,
                y: corner.y - (corner.y - previous.y) / inLength * r
            )
            let after = CGPoint(
                x: corner.x + (next.x - corner.x) / outLength * r,
                y: corner.y + (next.y - corner.y) / outLength * r
            )
            path.addLine(to: before)
            path.addQuadCurve(to: after, control: corner)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
