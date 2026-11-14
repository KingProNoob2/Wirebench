import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Routes the sheet's cables as orthogonal polylines.
///
/// One algorithm with three canonical shapes, tried in order of preference and taken as soon as one
/// clears every block:
///
/// 1. **Forward** — the target sits far enough right for two stubs and a corridor: out of the source
///    pin, one vertical in the gap, into the target pin.
/// 2. **Jog** — neighbouring blocks, no room for two stubs: a single vertical between the pins.
/// 3. **Detour** — running left, overlapping, or blocked across: get clear above or below (whichever
///    is nearer), cross on one shared track, come back in on the other side.
///
/// The shapes are the whole routing wherever one of them is clear. Only when none is (blocks packed too
/// tight for any of them) is there a search, `search`, which finds a way through on a fixed grid. An
/// earlier version kept an A* pass for the blocked cases and switched it off while a block was being
/// dragged, which is why cables used to jump when the mouse stopped; and its grid was built from the
/// obstacles' own edges, which is why they swam while it moved. This one runs whether or not a drag is
/// in progress, and is the same function of the same geometry every time, on lines every `pitch` points
/// that do not depend on any block. Every shape is likewise built the same way at every frame, and
/// corridors and tracks are found by scanning outward from the obvious place in fixed steps — cheap, and
/// a block moving a few points does not move a line that was found by scanning.
///
/// Cables are routed one at a time, so where several share a gap they land on the same line;
/// `WireSeparation` runs afterwards over the whole page and sets them side by side.
///
/// The shapes are what Dirigo's own default routing looks like: stubs at the pins, one or two turns,
/// and a fan of cables that must detour sharing one track and separating on their legs, so the group
/// reads as a bus rather than as a tangle.
public enum WireRouter {

    /// How far a cable runs out of its pin before its first turn.
    public static let stub: CGFloat = 18
    /// How far a route keeps from a block it is not connected to.
    public static let clearance: CGFloat = 10
    /// Spacing between parallel cables sharing a run.
    public static let laneSpacing: Double = 10
    /// The widest band a group of cables may spread across.
    public static let laneBand: Double = 120
    /// The grid a drag's dead zone is measured in, in points; see `WireRouteCache`'s anchors.
    public static let pitch: CGFloat = 8
    /// The step corridors and tracks are scanned in.
    private static let scan: CGFloat = 8

    /// Side-by-side offsets for a group of cables, centred on the run they share and ordered by where
    /// each one lands, so a fan leaves and arrives in the same order and does not cross itself.
    public static func lanes(forLandings landings: [Double]) -> [Double] {
        guard landings.count > 1 else { return landings.map { _ in 0 } }
        let sorted = landings.sorted()
        let centre = Double(sorted.count - 1) / 2
        let step = min(laneSpacing, laneBand / Double(sorted.count - 1))
        return landings.indices.map { (Double($0) - centre) * step }
    }

    /// The route for one cable.
    ///
    /// - Parameters:
    ///   - lane: a small offset for the corridor or jog, so cables sharing a run sit side by side
    ///     instead of stacking into one line.
    ///   - legSpread: a non-negative offset for the *legs* of a detour. One cable in a group gets 0,
    ///     the next one step, and so on, so a fan that must loop around a block descends on separate
    ///     lines while sharing one track.
    ///   - obstacles: rectangles to route around. Normally every block on the page except the two
    ///     being connected.
    ///   - clearAbove / clearBelow: the Y a detour's track may not cross, above and below. The canvas
    ///     passes the connected blocks' own extents, so a detour never clips the blocks it belongs to.
    ///   - ends: the two connected blocks. A cable may leave and enter them through their pins, but
    ///     must not cut across them anywhere else.
    public static func route(
        from src: CGPoint,
        to dst: CGPoint,
        lane: Double = 0,
        legSpread: Double = 0,
        obstacles: [CGRect] = [],
        clearAbove: Double? = nil,
        clearBelow: Double = 0,
        ends: [CGRect] = []
    ) -> [CGPoint] {
        let gap = dst.x - src.x
        // A stub is `stub` long unless a block stands in front of the pin, in which case it stops short of it.
        let out = stubLength(at: src, towards: 1, obstacles: obstacles)
        let into = stubLength(at: dst, towards: -1, obstacles: obstacles)
        var primary: [CGPoint]?
        var primaryHits = Int.max
        if gap > out + into + scan {
            let path = forward(from: src, to: dst, lane: lane, obstacles: obstacles, out: out, into: into)
            let hits = crossings(path, obstacles: obstacles, ends: ends)
            if hits == 0 { return path }
            primary = path
            primaryHits = hits
        } else if gap > 0 {
            let path = jog(from: src, to: dst, lane: lane, obstacles: obstacles)
            let hits = crossings(path, obstacles: obstacles, ends: ends)
            if hits == 0 { return path }
            primary = path
            primaryHits = hits
        }

        // The first shape that clears every block wins. Only compute `detour` when the forward/jog
        // shape could not clear, and only run `search` when none of the three shapes is clear.
        let detourPath = detour(from: src, to: dst, legSpread: legSpread, obstacles: obstacles,
                                clearAbove: clearAbove, clearBelow: clearBelow, ends: ends, out: out, into: into)
        let detourHits = crossings(detourPath, obstacles: obstacles, ends: ends)
        if detourHits == 0 { return detourPath }

        let bestPath: [CGPoint]
        let bestHits: Int
        if let primary, primaryHits <= detourHits {
            bestPath = primary
            bestHits = primaryHits
        } else {
            bestPath = detourPath
            bestHits = detourHits
        }
        // Only when none of the three shapes is clear, on a crowded sheet, is there a search for a way through, so every cable the
        // shapes can route keeps the shape it has always had. The search is the same function of the same geometry every time it
        // runs, on a fixed grid, so what it finds does not change from one frame to the next.
        if bestHits > 0, let found = search(from: src, to: dst, obstacles: obstacles, ends: ends, out: out, into: into),
           crossings(found, obstacles: obstacles, ends: ends) < bestHits {
            return found
        }
        return bestPath
    }

    // MARK: - The way through a crowded sheet

    /// A path from `src` to `dst` that clears every block, found by A* over a fixed grid of horizontal and vertical lines.
    ///
    /// The lines are every `pitch` points on the sheet, plus the stub ends' own rows and columns, so a path can meet the pins exactly. A
    /// turn costs as much as a stretch of cable, so the path prefers few corners, the way the three shapes do. It leaves the source
    /// and enters the destination with a stub, like every other cable. Returns nil when there is no way through, or the search would
    /// take too long, and the caller keeps the best shape it had.
    static func search(from src: CGPoint, to dst: CGPoint, obstacles: [CGRect], ends: [CGRect],
                       out: CGFloat = stub, into: CGFloat = stub) -> [CGPoint]? {
        // First with room to spare around every block; then, if blocks are packed too tight for that, close to them. A cable that
        // hugs a block is better than one through it.
        search(from: src, to: dst, obstacles: obstacles, ends: ends, out: out, into: into, inflate: 5)
            ?? search(from: src, to: dst, obstacles: obstacles, ends: ends, out: out, into: into, inflate: 1.5)
    }

    private static func search(from src: CGPoint, to dst: CGPoint, obstacles: [CGRect], ends: [CGRect],
                               out: CGFloat, into: CGFloat, inflate: CGFloat) -> [CGPoint]? {
        let a = CGPoint(x: src.x + out, y: src.y)
        let b = CGPoint(x: dst.x - into, y: dst.y)
        let margin: CGFloat = 96
        let region = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -margin, dy: -margin)
        var blocks: [CGRect] = []
        blocks.reserveCapacity(obstacles.count + ends.count)
        for rect in obstacles where rect.intersects(region) {
            blocks.append(rect.insetBy(dx: -inflate, dy: -inflate))
        }
        for rect in ends where rect.intersects(region) {
            blocks.append(rect.insetBy(dx: -inflate, dy: -inflate))
        }

        func lines(_ low: CGFloat, _ high: CGFloat, _ e0: CGFloat, _ e1: CGFloat) -> [CGFloat] {
            var values: [CGFloat] = []
            values.reserveCapacity(max(4, Int((high - low) / pitch) + 4))
            let lo = min(e0, e1), hi = max(e0, e1)
            var insertedLo = false, insertedHi = false
            var v = (low / pitch).rounded(.up) * pitch
            while v <= high {
                if !insertedLo && lo <= v {
                    if lo < v { values.append(lo) }
                    insertedLo = true
                }
                if !insertedHi && hi <= v {
                    if hi < v && hi != lo { values.append(hi) }
                    insertedHi = true
                }
                values.append(v)
                v += pitch
            }
            if !insertedLo { values.append(lo) }
            if !insertedHi && hi != lo { values.append(hi) }
            return values
        }
        func upperBound(_ arr: [CGFloat], _ target: CGFloat) -> Int {
            var lo = 0, hi = arr.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if arr[mid] <= target { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func lowerBound(_ arr: [CGFloat], _ target: CGFloat) -> Int {
            var lo = 0, hi = arr.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if arr[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        let xs = lines(region.minX, region.maxX, a.x, b.x)
        let ys = lines(region.minY, region.maxY, a.y, b.y)
        let startX = lowerBound(xs, a.x), startY = lowerBound(ys, a.y)
        let goalX = lowerBound(xs, b.x), goalY = lowerBound(ys, b.y)
        guard startX < xs.count, xs[startX] == a.x,
              startY < ys.count, ys[startY] == a.y,
              goalX < xs.count, xs[goalX] == b.x,
              goalY < ys.count, ys[goalY] == b.y else { return nil }

        let columns = xs.count, rows = ys.count
        let cellCount = columns * rows
        let stateCount = cellCount * 4
        guard stateCount <= 2_000_000 else { return nil }

        var blocked = [Bool](repeating: false, count: cellCount)
        for block in blocks {
            let xStart = upperBound(xs, block.minX)
            let xEnd = lowerBound(xs, block.maxX)
            guard xStart < xEnd else { continue }
            let yStart = upperBound(ys, block.minY)
            let yEnd = lowerBound(ys, block.maxY)
            guard yStart < yEnd else { continue }
            for yi in yStart..<yEnd {
                let rowBase = yi * columns
                for xi in xStart..<xEnd {
                    blocked[rowBase + xi] = true
                }
            }
        }
        // The ends of the stubs sit outside their blocks; if one is not (blocks piled on a pin) there is nothing to search for.
        if blocked[startY * columns + startX] || blocked[goalY * columns + goalX] { return nil }

        // Directions: 0 east, 1 south, 2 west, 3 north.
        let stepX = (1, 0, -1, 0)
        let stepY = (0, 1, 0, -1)
        let turnCost: CGFloat = 16
        var best = [CGFloat](repeating: .infinity, count: stateCount)
        var from = [Int32](repeating: -1, count: stateCount)

        struct HeapEntry {
            var priority: CGFloat
            var cost: CGFloat
            var state: Int32
        }
        var heap: [HeapEntry] = []
        heap.reserveCapacity(256)
        func push(_ priority: CGFloat, _ cost: CGFloat, _ state: Int32) {
            heap.append(HeapEntry(priority: priority, cost: cost, state: state))
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) >> 1
                if heap[parent].priority <= heap[i].priority { break }
                heap.swapAt(i, parent)
                i = parent
            }
        }
        func pop() -> HeapEntry {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                let count = heap.count
                var i = 0
                while true {
                    let left = (i << 1) + 1
                    if left >= count { break }
                    var smallest = left
                    let right = left + 1
                    if right < count && heap[right].priority < heap[smallest].priority {
                        smallest = right
                    }
                    if heap[smallest].priority >= heap[i].priority { break }
                    heap.swapAt(i, smallest)
                    i = smallest
                }
            }
            return top
        }

        let startIdx = (startY * columns + startX) * 4
        best[startIdx] = 0
        push(abs(xs[startX] - b.x) + abs(ys[startY] - b.y), 0, Int32(startIdx))
        var pops = 0
        var goalIdx = -1
        while !heap.isEmpty {
            let top = pop()
            pops += 1
            if pops > 25_000 { return nil }
            let stateIdx = Int(top.state)
            let cost = top.cost
            if cost > best[stateIdx] { continue }
            let direction = stateIdx & 3
            let cell = stateIdx >> 2
            let sy = cell / columns
            let sx = cell - sy * columns
            if sx == goalX && sy == goalY && direction == 0 { goalIdx = stateIdx; break }

            let curX = xs[sx], curY = ys[sy]
            let reverseDir = direction ^ 2
            for nextDir in 0..<4 where nextDir != reverseDir {
                let dx: Int
                let dy: Int
                switch nextDir {
                case 0: dx = stepX.0; dy = stepY.0
                case 1: dx = stepX.1; dy = stepY.1
                case 2: dx = stepX.2; dy = stepY.2
                default: dx = stepX.3; dy = stepY.3
                }
                let nx = sx + dx, ny = sy + dy
                guard nx >= 0, nx < columns, ny >= 0, ny < rows else { continue }
                let nCell = ny * columns + nx
                if blocked[nCell] { continue }
                // The stub into the destination arrives heading east, so a path that reaches it any other way pays to turn.
                let length = abs(xs[nx] - curX) + abs(ys[ny] - curY)
                var next = cost + length + (nextDir == direction ? 0 : turnCost)
                if nx == goalX && ny == goalY && nextDir != 0 { next += turnCost }
                let nextIdx = (nCell << 2) | nextDir
                if next < best[nextIdx] {
                    best[nextIdx] = next
                    from[nextIdx] = top.state
                    let estimate = abs(xs[nx] - b.x) + abs(ys[ny] - b.y)
                    push(next + estimate, next, Int32(nextIdx))
                }
            }
        }
        guard goalIdx >= 0 else { return nil }

        var cells: [CGPoint] = []
        var cur = Int32(goalIdx)
        while cur >= 0 {
            let cell = Int(cur) >> 2
            let cy = cell / columns
            let cx = cell - cy * columns
            cells.append(CGPoint(x: xs[cx], y: ys[cy]))
            cur = from[Int(cur)]
        }
        cells.reverse()
        // Keep only the corners, and the two stub ends.
        var corners: [CGPoint] = [src]
        corners.reserveCapacity(cells.count + 2)
        for (i, point) in cells.enumerated() {
            let isEnd = i == 0 || i == cells.count - 1
            if isEnd { corners.append(point); continue }
            let before = cells[i - 1], after = cells[i + 1]
            let straight = (before.x == point.x && point.x == after.x) || (before.y == point.y && point.y == after.y)
            if !straight { corners.append(point) }
        }
        corners.append(dst)
        return clean(corners)
    }

    /// Whether a path still clears every one of `rects`.
    ///
    /// What lets a cable the drag does not move keep its route instead of being recomputed every frame
    /// — and re-route only once a dragged block is actually in its way, rather than either sitting
    /// under it or twitching for as long as the mouse is down.
    public static func isClear(_ points: [CGPoint], of rects: [CGRect]) -> Bool {
        guard points.count >= 2 else { return true }
        let b = pathBounds(points)
        for rect in rects {
            guard rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY && rect.minY < b.maxY else { continue }
            for i in 0..<(points.count - 1) {
                if crosses(points[i], points[i + 1], rect) { return false }
            }
        }
        return true
    }

    /// Whether a path clears every obstacle except the two modules the cable connects.
    public static func isClear(_ points: [CGPoint], of obstacles: [(id: Int, rect: CGRect)],
                               excluding firstId: Int, and secondId: Int) -> Bool {
        guard points.count >= 2 else { return true }
        let b = pathBounds(points)
        for (id, rect) in obstacles where id != firstId && id != secondId {
            guard rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY && rect.minY < b.maxY else { continue }
            for i in 0..<(points.count - 1) {
                if crosses(points[i], points[i + 1], rect) { return false }
            }
        }
        return true
    }

    /// How long the stub at a pin is. `towards` is +1 for an output pin (the stub runs right) and -1 for an input (it runs left, into the pin).
    ///
    /// Eighteen points, unless a block stands within that of the pin on its row: blocks laid close together leave less than a stub's length
    /// between an output and its neighbour, and a stub that long pokes into the neighbour, which no route from that pin can then avoid. It
    /// stops a little short of the block instead, but never under `shortestStub`.
    static func stubLength(at pin: CGPoint, towards direction: CGFloat, obstacles: [CGRect]) -> CGFloat {
        var room = stub
        for rect in obstacles where pin.y > rect.minY && pin.y < rect.maxY {
            let distance = direction > 0 ? rect.minX - pin.x : pin.x - rect.maxX
            if distance > 0 && distance - 4 < room { room = distance - 4 }
        }
        return max(shortestStub, room)
    }
    /// The shortest a stub may be made, so a pin still reads as a pin with a cable leaving it.
    static let shortestStub: CGFloat = 6

    // MARK: - The three shapes

    /// Stub out, one vertical in the gap, stub in.
    private static func forward(from src: CGPoint, to dst: CGPoint,
                                lane: Double, obstacles: [CGRect], out: CGFloat, into: CGFloat) -> [CGPoint] {
        let a = CGPoint(x: src.x + out, y: src.y)
        let b = CGPoint(x: dst.x - into, y: dst.y)
        let mid = (a.x + b.x) / 2
        let corridor = clearVertical(near: mid + CGFloat(lane), within: (a.x, b.x),
                                     top: min(a.y, b.y), bottom: max(a.y, b.y),
                                     fallback: mid, obstacles: obstacles)
        return clean([src, a, CGPoint(x: corridor, y: a.y), CGPoint(x: corridor, y: b.y), b, dst])
    }

    /// One vertical between neighbouring pins, kept inside the gap: a jog wider than the gap would
    /// push past the pins and into the blocks.
    private static func jog(from src: CGPoint, to dst: CGPoint,
                            lane: Double, obstacles: [CGRect]) -> [CGPoint] {
        let mid = (src.x + dst.x) / 2
        let low = src.x + 2
        let high = max(low, dst.x - 2)
        let wanted = min(max(mid + CGFloat(lane), low), high)
        let top = min(src.y, dst.y), bottom = max(src.y, dst.y)
        let x = blocksVertically(x: wanted, top: top, bottom: bottom, obstacles: obstacles) ? mid : wanted
        return clean([src, CGPoint(x: x, y: src.y), CGPoint(x: x, y: dst.y), dst])
    }

    /// Up (or down) to a shared track, across, and back in — for cables that run left, overlap, or
    /// have a block across the straight run.
    private static func detour(from src: CGPoint, to dst: CGPoint, legSpread: Double,
                               obstacles: [CGRect], clearAbove: Double?, clearBelow: Double,
                               ends: [CGRect], out: CGFloat, into: CGFloat) -> [CGPoint] {
        let a = CGPoint(x: src.x + out, y: src.y)
        let b = CGPoint(x: dst.x - into, y: dst.y)
        let left = min(a.x, b.x), right = max(a.x, b.x)
        let pinTop = min(a.y, b.y), pinBottom = max(a.y, b.y)
        // The bounds the caller sets: outside the connected blocks' own extent, so a detour never
        // clips the blocks it belongs to. The pin terms are a fallback for callers that pass nothing.
        let ceiling = min(CGFloat(clearAbove ?? Double(pinTop - 60)), pinTop - clearance)
        let floor = max(CGFloat(clearBelow), pinBottom + clearance)
        // The track has to clear the connected blocks, which is what `clearAbove`/`clearBelow` bound;
        // within those bounds the candidates are the channels between the blocks in the way — each
        // one's edges, offset by the clearance — plus the two bounds themselves. Nearest to the pins
        // first, so a cable steps over a neighbour rather than climbing over the whole sheet, which is
        // what a detour to the far bound drew: legs hundreds of points long for a block in the way.
        var candidates: [CGFloat] = [ceiling, floor]
        var relevantX: [CGRect] = []
        let pathMinX = min(src.x, left)
        let pathMaxX = max(dst.x, right)
        for rect in obstacles {
            if rect.maxX > left && rect.minX < right {
                candidates.append(rect.maxY + clearance)
                candidates.append(rect.minY - clearance)
            }
            if rect.maxX > pathMinX - clearance && rect.minX < pathMaxX + clearance {
                relevantX.append(rect)
            }
        }
        let pinMid = (pinTop + pinBottom) / 2
        var seenTracks: Set<CGFloat> = []
        let tracks = candidates
            .filter { y in
                guard y >= ceiling - 0.5, y <= floor + 0.5 else { return false }
                // A channel through a connected block's own row would cut across that block, so only
                // the rows outside both of them are candidates.
                guard !ends.contains(where: { end in
                    let grown = end.insetBy(dx: -clearance, dy: -clearance)
                    return y > grown.minY && y < grown.maxY
                }) else { return false }
                return seenTracks.insert(y).inserted
            }
            .sorted { abs($0 - pinMid) < abs($1 - pinMid) }

        var fallback: [CGPoint] = []
        for track in tracks {
            let outX = clearVertical(near: a.x + CGFloat(legSpread), within: (left, right),
                                     top: min(a.y, track), bottom: max(a.y, track),
                                     fallback: a.x, obstacles: relevantX)
            let inX = clearVertical(near: b.x - CGFloat(legSpread), within: (left, right),
                                    top: min(b.y, track), bottom: max(b.y, track),
                                    fallback: b.x, obstacles: relevantX)
            let path = clean([src, CGPoint(x: outX, y: a.y), CGPoint(x: outX, y: track),
                              CGPoint(x: inX, y: track), CGPoint(x: inX, y: b.y), dst])
            if fallback.isEmpty { fallback = path }
            // The legs and the track are each clear by construction, but the runs back into the pins
            // are not: a leg placed left of a block still leaves the last horizontal crossing it.
            // The whole path is what has to be clear.
            if !hasCrossing(path, obstacles: relevantX, ends: ends) { return path }
        }
        return fallback
    }

    // MARK: - Finding clear lines

    /// The nearest X to `near` inside `within` whose vertical run from `top` to `bottom` clears every
    /// block, scanning outward in `scan` steps so the answer moves in steps rather than sliding.
    private static func clearVertical(near: CGFloat, within: (CGFloat, CGFloat),
                                      top: CGFloat, bottom: CGFloat,
                                      fallback: CGFloat, obstacles: [CGRect]) -> CGFloat {
        let candidate = min(max(near, within.0), within.1)
        var blockedX: [(CGFloat, CGFloat)] = []
        for rect in obstacles {
            let minY = rect.minY - clearance
            let maxY = rect.maxY + clearance
            guard top < maxY && bottom > minY else { continue }
            let minX = rect.minX - clearance
            let maxX = rect.maxX + clearance
            guard maxX > within.0 && minX < within.1 else { continue }
            blockedX.append((minX, maxX))
        }
        if blockedX.isEmpty { return candidate }
        func isBlocked(_ x: CGFloat) -> Bool {
            for (lo, hi) in blockedX where x > lo && x < hi { return true }
            return false
        }
        if !isBlocked(candidate) { return candidate }
        var step: CGFloat = scan
        let span = within.1 - within.0
        while step <= span {
            let left = candidate - step
            if left >= within.0 && left <= within.1 && !isBlocked(left) { return left }
            let right = candidate + step
            if right >= within.0 && right <= within.1 && !isBlocked(right) { return right }
            step += scan
        }
        return fallback
    }

    private static func blocksVertically(x: CGFloat, top: CGFloat, bottom: CGFloat,
                                         obstacles: [CGRect]) -> Bool {
        // Scanning keeps the clearance, so a corridor or leg never ends up glued to a block's edge.
        // `crossings`, which decides whether a finished shape is acceptable, uses the raw rectangles.
        obstacles.contains { crosses(CGPoint(x: x, y: top), CGPoint(x: x, y: bottom),
                                     $0.insetBy(dx: -clearance, dy: -clearance)) }
    }

    private static func pathBounds(_ points: [CGPoint]) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        var minX = points[0].x, maxX = minX
        var minY = points[0].y, maxY = minY
        for i in 1..<points.count {
            let p = points[i]
            if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
        }
        return (minX, maxX, minY, maxY)
    }

    private static func hasCrossing(_ points: [CGPoint], obstacles: [CGRect], ends: [CGRect]) -> Bool {
        guard points.count >= 2 else { return false }
        let b = pathBounds(points)
        for rect in obstacles {
            guard rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY && rect.minY < b.maxY else { continue }
            for i in 0..<(points.count - 1) {
                if crosses(points[i], points[i + 1], rect) { return true }
            }
        }
        for rect in ends {
            guard rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY && rect.minY < b.maxY else { continue }
            for i in 0..<(points.count - 1) {
                if crosses(points[i], points[i + 1], rect) { return true }
            }
        }
        return false
    }

    /// How many of `obstacles` and `ends` a path cuts across.
    static func crossings(_ points: [CGPoint], obstacles: [CGRect], ends: [CGRect]) -> Int {
        guard points.count >= 2 else { return 0 }
        let b = pathBounds(points)
        var total = 0
        for rect in obstacles {
            guard rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY && rect.minY < b.maxY else { continue }
            for i in 0..<(points.count - 1) {
                if crosses(points[i], points[i + 1], rect) { total += 1 }
            }
        }
        for rect in ends {
            guard rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY && rect.minY < b.maxY else { continue }
            for i in 0..<(points.count - 1) {
                if crosses(points[i], points[i + 1], rect) { total += 1 }
            }
        }
        return total
    }

    private static func crosses(_ p: CGPoint, _ q: CGPoint, _ rect: CGRect) -> Bool {
        min(p.x, q.x) < rect.maxX && max(p.x, q.x) > rect.minX
            && min(p.y, q.y) < rect.maxY && max(p.y, q.y) > rect.minY
            && (p.x == q.x ? (p.x > rect.minX && p.x < rect.maxX) : (p.y > rect.minY && p.y < rect.maxY))
    }

    /// Drops repeated points. Collinear middles stay: the stub points beside the pins are collinear
    /// with the run they start, and dropping them would lose the corners' context and the shape the
    /// tests — and the rounding — expect.
    private static func clean(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for point in points where out.last != point { out.append(point) }
        return out
    }

    // MARK: - Drawing

    /// Splits any diagonal segment into two axis-aligned ones.
    ///
    /// A cable drawn by hand in Dirigo can have a `POINTS` route whose consecutive points differ in
    /// both coordinates; followed literally it draws as a diagonal, which reads as a bent string next
    /// to the orthogonal ones. The corner continues the direction the cable was already going, so the
    /// step does not introduce an S-bend.
    public static func orthogonalized(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var alreadyOrthogonal = true
        for i in 1..<points.count {
            let prev = points[i - 1], cur = points[i]
            if prev == cur || (prev.x != cur.x && prev.y != cur.y) {
                alreadyOrthogonal = false
                break
            }
        }
        if alreadyOrthogonal { return points }
        var result: [CGPoint] = [points[0]]
        result.reserveCapacity(points.count)
        for point in points.dropFirst() {
            guard let last = result.last, last != point else { continue }
            if last.x != point.x && last.y != point.y {
                // Continue horizontally first: cables leave and enter pins along their row.
                result.append(CGPoint(x: point.x, y: last.y))
            }
            result.append(point)
        }
        return result
    }

    /// One step of a path, with no platform's path type: what a frontend replays into its own.
    public enum PathSegment: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(to: CGPoint, control: CGPoint)
    }

    /// The path to stroke: the route's corners rounded, including the ones at the pins' stubs.
    public static func roundedSegments(_ points: [CGPoint], radius: CGFloat = 7) -> [PathSegment] {
        guard !points.isEmpty else { return [] }
        let simplified = removingCollinearMidpoints(points)
        var segments: [PathSegment] = []
        segments.reserveCapacity(simplified.count * 2)
        guard let first = simplified.first else { return segments }
        segments.append(.move(first))
        guard simplified.count > 2 else {
            if let last = simplified.last { segments.append(.line(last)) }
            return segments
        }
        for index in 1..<(simplified.count - 1) {
            let previous = simplified[index - 1], corner = simplified[index], next = simplified[index + 1]
            let inLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outLength = hypot(next.x - corner.x, next.y - corner.y)
            let r = min(radius, inLength / 2, outLength / 2)
            guard r > 0.5, inLength > 0, outLength > 0 else {
                segments.append(.line(corner))
                continue
            }
            let before = CGPoint(x: corner.x - (corner.x - previous.x) / inLength * r,
                                 y: corner.y - (corner.y - previous.y) / inLength * r)
            let after = CGPoint(x: corner.x + (next.x - corner.x) / outLength * r,
                                y: corner.y + (next.y - corner.y) / outLength * r)
            segments.append(.line(before))
            segments.append(.quad(to: after, control: corner))
        }
        segments.append(.line(simplified[simplified.count - 1]))
        return segments
    }

    private static func isCollinearMidpoint(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
        let straight = (p.x == q.x && q.x == r.x) || (p.y == q.y && q.y == r.y)
        guard straight else { return false }
        return (min(p.x, r.x)...max(p.x, r.x)).contains(q.x)
            && (min(p.y, r.y)...max(p.y, r.y)).contains(q.y)
    }

    /// A point in the middle of a straight run (the stub end, where a cable leaves its pin) is no
    /// corner, but it splits the run — and a corner's radius is capped by half its neighbouring
    /// segments, so it would round one corner tighter than the others. Drop such points first.
    private static func removingCollinearMidpoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        result.append(points[0])
        for i in 1..<(points.count - 1) {
            if !isCollinearMidpoint(result[result.count - 1], points[i], points[i + 1]) {
                result.append(points[i])
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    #if canImport(CoreGraphics)
    /// `roundedSegments` as a Core Graphics path, built directly without intermediate segment arrays.
    public static func roundedPath(_ points: [CGPoint], radius: CGFloat = 7) -> CGPath {
        let path = CGMutablePath()
        let count = points.count
        guard count > 0 else { return path }
        path.move(to: points[0])
        guard count > 2 else {
            path.addLine(to: points[count - 1])
            return path
        }
        var previous = points[0]
        var i = 1
        while i < count - 1 {
            let corner = points[i]
            if isCollinearMidpoint(previous, corner, points[i + 1]) {
                i += 1
                continue
            }
            var nextIdx = i + 1
            while nextIdx < count - 1 && isCollinearMidpoint(corner, points[nextIdx], points[nextIdx + 1]) {
                nextIdx += 1
            }
            let next = points[nextIdx]
            let inLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outLength = hypot(next.x - corner.x, next.y - corner.y)
            let r = min(radius, inLength / 2, outLength / 2)
            if r > 0.5, inLength > 0, outLength > 0 {
                let before = CGPoint(x: corner.x - (corner.x - previous.x) / inLength * r,
                                     y: corner.y - (corner.y - previous.y) / inLength * r)
                let after = CGPoint(x: corner.x + (next.x - corner.x) / outLength * r,
                                    y: corner.y + (next.y - corner.y) / outLength * r)
                path.addLine(to: before)
                path.addQuadCurve(to: after, control: corner)
            } else {
                path.addLine(to: corner)
            }
            previous = corner
            i = nextIdx
        }
        path.addLine(to: points[count - 1])
        return path
    }
    #endif
}
