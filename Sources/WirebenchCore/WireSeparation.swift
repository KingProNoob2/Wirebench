import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pulls apart cables of different signals that run on the same line.
///
/// `WireRouter` routes each cable on its own, and picks the middle of a gap for its corridor, so every cable crossing the same gap
/// from different blocks lands on the same line: a bundle of ten reads as one, and there is no telling where each goes. The lanes
/// `WireRouter.lanes` hands out only separate cables leaving the *same* block.
///
/// This runs once over the finished routes of a whole page. Where two or more signals share a run (their lines within `tolerance`,
/// and their extents overlapping), it sets them side by side, `spacing` apart and centred on where they were, in the order that makes
/// the horizontals they feed cross each other least. It only moves a run that can move without breaking the cable: the stubs at the
/// pins stay, every corner stays a right angle, nothing flips direction, and a move that would put a cable through a block it did
/// not cross before is not made.
public enum WireSeparation {
    /// One cable, as the router left it.
    public struct Item {
        /// The signal: cables from the same output pin share a run on purpose and stay together.
        public var net: Int
        public var points: [CGPoint]
        /// False for a cable drawn by hand in the original program, which is followed exactly.
        public var movable: Bool
        /// The two blocks it joins, which it may touch; every other block is an obstacle.
        public var from: Int
        public var to: Int

        public init(net: Int, points: [CGPoint], movable: Bool, from: Int, to: Int) {
            self.net = net; self.points = points; self.movable = movable; self.from = from; self.to = to
        }
    }

    /// Distance between two cables in a lane group.
    public static let spacing: CGFloat = 8
    /// Runs closer than this count as one line.
    public static let tolerance: CGFloat = 6
    /// How close to its neighbouring corner a run may be pushed.
    private static let margin: CGFloat = 6
    /// The shortest a stub at a pin may be made to give a crowded gap room: still a visible lead-in, not a cable cut off at the pin.
    private static let shortestStub: CGFloat = 8
    /// The closest two lanes may be pushed.
    private static let narrowest: CGFloat = 3.5

    private enum Axis { case vertical, horizontal }

    /// A straight run that can slide sideways.
    private struct Run {
        var item: Int
        var index: Int          // the run is points[index] -> points[index + 1]
        var position: CGFloat   // where it sits across its direction (x for a vertical run)
        var low: CGFloat        // its extent along its direction
        var high: CGFloat
        var minPosition: CGFloat
        var maxPosition: CGFloat
        /// Where, along the run, the horizontals that meet it leave towards smaller / larger `position`.
        var towardsLow: [CGFloat]
        var towardsHigh: [CGFloat]
        /// The corner before / after this run is the end of a stub at a pin, which may be shortened to make room.
        var shortensStart = false
        var shortensEnd = false
    }

    public static func separate(_ items: [Item], obstacles: [(id: Int, rect: CGRect)]) -> [[CGPoint]] {
        var paths = items.map(\.points)
        for axis in [Axis.vertical, .horizontal] {
            separate(axis: axis, items: items, paths: &paths, obstacles: obstacles)
        }
        return paths
    }

    // MARK: - One direction

    private static func across(_ p: CGPoint, _ axis: Axis) -> CGFloat { axis == .vertical ? p.x : p.y }
    private static func along(_ p: CGPoint, _ axis: Axis) -> CGFloat { axis == .vertical ? p.y : p.x }
    private static func setAcross(_ p: inout CGPoint, _ value: CGFloat, _ axis: Axis) {
        if axis == .vertical { p.x = value } else { p.y = value }
    }

    private static func runs(of path: [CGPoint], item: Int, axis: Axis) -> [Run] {
        let n = path.count
        guard n >= 4 else { return [] }
        var found: [Run] = []
        // A run touching the first or last point is a stub at a pin, which stays.
        for i in 1...(n - 3) {
            let p = path[i], q = path[i + 1]
            guard abs(across(p, axis) - across(q, axis)) < 0.01, abs(along(p, axis) - along(q, axis)) > 0.01 else { continue }
            let before = path[i - 1], after = path[i + 2]
            // Both neighbours must run square to this one, or sliding it would bend them.
            guard abs(along(before, axis) - along(p, axis)) < 0.01, abs(along(after, axis) - along(q, axis)) < 0.01,
                  abs(across(before, axis) - across(p, axis)) > 0.01, abs(across(after, axis) - across(q, axis)) > 0.01
            else { continue }
            let position = across(p, axis)
            var low: [CGFloat] = [], high: [CGFloat] = []
            var minPosition = -CGFloat.infinity, maxPosition = CGFloat.infinity
            var shortensStart = false, shortensEnd = false
            for (neighbour, at, isStubEnd, anchor) in [(before, along(p, axis), i - 1 == 1, path[0]),
                                                       (after, along(q, axis), i + 2 == n - 2, path[n - 1])] {
                // Next to a stub the run may go as near the pin as a shortened stub allows, not just as near as the corner.
                let reach = isStubEnd ? across(anchor, axis) : across(neighbour, axis)
                let room = isStubEnd ? shortestStub + 4 : margin
                if across(neighbour, axis) < position {
                    low.append(at)
                    minPosition = max(minPosition, reach + room)
                } else {
                    high.append(at)
                    maxPosition = min(maxPosition, reach - room)
                }
                if isStubEnd { if neighbour == before { shortensStart = true } else { shortensEnd = true } }
            }
            found.append(Run(item: item, index: i, position: position,
                             low: min(along(p, axis), along(q, axis)), high: max(along(p, axis), along(q, axis)),
                             minPosition: minPosition, maxPosition: maxPosition, towardsLow: low, towardsHigh: high,
                             shortensStart: shortensStart, shortensEnd: shortensEnd))
        }
        return found
    }

    private static func separate(axis: Axis, items: [Item], paths: inout [[CGPoint]], obstacles: [(id: Int, rect: CGRect)]) {
        var all: [Run] = []
        for (index, item) in items.enumerated() where item.movable {
            all.append(contentsOf: runs(of: paths[index], item: index, axis: axis))
        }
        guard all.count > 1 else { return }

        // Runs on one line: close together across, overlapping along. A union-find over the pairs.
        var parent = Array(all.indices)
        func root(_ i: Int) -> Int { var r = i; while parent[r] != r { r = parent[r] }; parent[i] = r; return r }
        let order = all.indices.sorted { all[$0].position < all[$1].position }
        for (slot, i) in order.enumerated() {
            for j in order[(slot + 1)...] {
                if all[j].position - all[i].position >= tolerance { break }
                if all[i].low - 2 <= all[j].high && all[j].low - 2 <= all[i].high { parent[root(i)] = root(j) }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in all.indices { clusters[root(i), default: []].append(i) }

        for key in clusters.keys.sorted() {
            let members = clusters[key]!
            let nets = Set(members.map { items[all[$0].item].net })
            guard nets.count > 1 else { continue }
            place(members.map { all[$0] }, items: items, paths: &paths, obstacles: obstacles, axis: axis)
        }
    }

    /// Sets the runs of one cluster side by side.
    private static func place(_ runs: [Run], items: [Item], paths: inout [[CGPoint]],
                              obstacles: [(id: Int, rect: CGRect)], axis: Axis) {
        var byNet: [Int: [Run]] = [:]
        for run in runs { byNet[items[run.item].net, default: []].append(run) }

        // Left to right (or top to bottom) in the order that crosses least: each signal goes where it adds the fewest crossings
        // between the horizontals that reach the runs.
        func cost(_ first: [Run], _ second: [Run]) -> Int {
            // `first` placed before `second` (towards smaller positions).
            var total = 0
            let firstLow = first.map(\.low).min()!, firstHigh = first.map(\.high).max()!
            let secondLow = second.map(\.low).min()!, secondHigh = second.map(\.high).max()!
            // `second`'s horizontals that reach towards smaller positions pass over `first`'s run when they cross its extent.
            for y in second.flatMap(\.towardsLow) where y > firstLow && y < firstHigh { total += 1 }
            // And `first`'s that reach towards larger positions pass over `second`'s.
            for y in first.flatMap(\.towardsHigh) where y > secondLow && y < secondHigh { total += 1 }
            return total
        }
        var ordered: [Int] = []
        for net in byNet.keys.sorted() {
            var best = 0, bestCost = Int.max
            for slot in 0...ordered.count {
                var c = 0
                for (i, other) in ordered.enumerated() {
                    c += i < slot ? cost(byNet[other]!, byNet[net]!) : cost(byNet[net]!, byNet[other]!)
                }
                if c < bestCost { bestCost = c; best = slot }
            }
            ordered.insert(net, at: best)
        }

        // Each signal's own limits (its runs move together, so the tightest of them), and a position for each in the order chosen, one
        // `step` or more apart, as near where the cables were as those limits allow. The step shrinks only if nothing fits at the full one.
        // If even the narrowest step does not fit them all, the most hemmed-in signal is left where it is and the rest tried again:
        // some of a crowd pulled apart beats none.
        let centre = runs.map(\.position).reduce(0, +) / CGFloat(runs.count)
        var positions: [Int: CGFloat] = [:]       // by net
        var remaining = ordered
        while remaining.count > 1 {
            let lows = remaining.map { net in byNet[net]!.map(\.minPosition).max()! }
            let highs = remaining.map { net in byNet[net]!.map(\.maxPosition).min()! }
            let count = remaining.count
            func solve(_ step: CGFloat) -> [CGFloat]? {
                var at = (0..<count).map { centre + (CGFloat($0) - CGFloat(count - 1) / 2) * step }
                for k in 0..<count { at[k] = max(at[k], lows[k], k > 0 ? at[k - 1] + step : -.infinity) }
                for k in stride(from: count - 1, through: 0, by: -1) { at[k] = min(at[k], highs[k], k < count - 1 ? at[k + 1] - step : .infinity) }
                for k in 0..<count {
                    if at[k] < lows[k] - 0.01 || at[k] > highs[k] + 0.01 { return nil }
                    if k > 0 && at[k] - at[k - 1] < step - 0.01 { return nil }
                }
                return at
            }
            if let found = [spacing, 7, 6, 5, 4, narrowest].lazy.compactMap({ solve($0) }).first {
                for (net, position) in zip(remaining, found) { positions[net] = position }
                break
            }
            // The signal with the least room goes.
            let tightest = remaining.indices.min { highs[$0] - lows[$0] < highs[$1] - lows[$1] }!
            remaining.remove(at: tightest)
        }
        guard positions.count > 1 else { return }
        ordered = remaining

        var trial = paths
        for net in ordered {
            let target = positions[net]!
            for run in byNet[net]! {
                setAcross(&trial[run.item][run.index], target, axis)
                setAcross(&trial[run.item][run.index + 1], target, axis)
                // A stub the run has come up to is shortened with it, so it never points the wrong way.
                if run.shortensStart {
                    let stubEnd = across(trial[run.item][1], axis)
                    if stubEnd < run.position { setAcross(&trial[run.item][1], min(stubEnd, target - 4), axis) }
                    else { setAcross(&trial[run.item][1], max(stubEnd, target + 4), axis) }
                }
                if run.shortensEnd {
                    let last = trial[run.item].count - 2
                    let stubEnd = across(trial[run.item][last], axis)
                    if stubEnd < run.position { setAcross(&trial[run.item][last], min(stubEnd, target - 4), axis) }
                    else { setAcross(&trial[run.item][last], max(stubEnd, target + 4), axis) }
                }
            }
        }
        // Nothing may start crossing a block it did not cross before.
        for item in Set(runs.map(\.item)) {
            let others = obstacles.filter { $0.id != items[item].from && $0.id != items[item].to }.map(\.rect)
            let ends = obstacles.filter { $0.id == items[item].from || $0.id == items[item].to }.map(\.rect)
            if WireRouter.crossings(trial[item], obstacles: others, ends: ends)
                > WireRouter.crossings(paths[item], obstacles: others, ends: ends) { return }
        }
        paths = trial
    }
}
