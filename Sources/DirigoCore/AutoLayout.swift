import CoreGraphics
import Foundation

/// Arranges the blocks of a page so signals flow left to right.
///
/// A layered layout, in four steps:
///
/// 1. **Loops are cut.** A feedback wire (found by a depth-first walk in execution order) is set aside, so the
///    rest of the graph has a left-to-right order.
/// 2. **Columns.** Every block goes one column right of the furthest block feeding it. A block nothing feeds
///    moves up next to the first block it feeds, so a constant does not sit at the far left with a long wire.
/// 3. **Order within a column**, by repeated barycentre sweeps: each block moves towards the average position of
///    its neighbours in the next column, which is what removes most wire crossings.
/// 4. **Positions.** Columns are as wide as their widest block. Each block is lined up so its first wired input
///    is level with the pin that feeds it, then pushed down just enough not to overlap the block above.
///
/// Blocks with no wires at all are set out in rows below the rest. The layout keeps the page's top-left corner
/// where it was. Pure geometry: the caller supplies sizes and pin offsets, and writes the positions back.
public enum AutoLayout {
    public struct Node: Sendable {
        public var id: Int
        public var size: CGSize
        /// Execution order, which breaks ties so the result is deterministic and follows how the program runs.
        public var order: Int

        public init(id: Int, size: CGSize, order: Int) {
            self.id = id
            self.size = size
            self.order = order
        }
    }

    public struct Edge: Sendable {
        public var from: Int
        public var to: Int
        /// Vertical offsets of the two pins from the top of their blocks, for lining blocks up. `nil` for a wire
        /// that should count for the columns but not for the alignment (a parameter wire).
        public var fromPinY: CGFloat?
        public var toPinY: CGFloat?

        public init(from: Int, to: Int, fromPinY: CGFloat? = nil, toPinY: CGFloat? = nil) {
            self.from = from
            self.to = to
            self.fromPinY = fromPinY
            self.toPinY = toPinY
        }
    }

    /// Horizontal space between columns: room for the wires to turn.
    public static let columnGap: CGFloat = 90
    /// Vertical space between blocks in a column.
    public static let rowGap: CGFloat = 28

    /// New top-left corners, by node id.
    public static func positions(nodes: [Node], edges: [Edge], origin: CGPoint) -> [Int: CGPoint] {
        let nodes = nodes.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        let ids = Set(nodes.map(\.id))
        let edges = edges.filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Feedback wires: a wire to a block still being walked closes a loop.
        var successors: [Int: [Int]] = [:]
        for edge in edges { successors[edge.from, default: []].append(edge.to) }
        var state: [Int: Int] = [:]                // 1 walking, 2 done
        var backward = Set<[Int]>()
        func walk(_ id: Int) {
            state[id] = 1
            for next in successors[id] ?? [] {
                if state[next] == 1 { backward.insert([id, next]) } else if state[next] == nil { walk(next) }
            }
            state[id] = 2
        }
        for node in nodes where state[node.id] == nil { walk(node.id) }
        let forward = edges.filter { !backward.contains([$0.from, $0.to]) }

        var feeders: [Int: [Edge]] = [:], readers: [Int: [Edge]] = [:]
        for edge in forward {
            feeders[edge.to, default: []].append(edge)
            readers[edge.from, default: []].append(edge)
        }

        // 2. Columns: longest path from the sources, in a topological order of the forward wires.
        let wired = Set(edges.flatMap { [$0.from, $0.to] })
        var remaining = Dictionary(nodes.map { ($0.id, feeders[$0.id]?.count ?? 0) }, uniquingKeysWith: { a, _ in a })
        var queue = nodes.map(\.id).filter { remaining[$0] == 0 }
        var topological: [Int] = []
        while !queue.isEmpty {
            let id = queue.removeFirst()
            topological.append(id)
            for edge in readers[id] ?? [] {
                remaining[edge.to]! -= 1
                if remaining[edge.to] == 0 { queue.append(edge.to) }
            }
        }
        var column: [Int: Int] = [:]
        for id in topological {
            column[id] = (feeders[id] ?? []).map { column[$0.from]! + 1 }.max() ?? 0
        }
        // A source moves up next to the first block it feeds.
        for id in topological.reversed() where (feeders[id] ?? []).isEmpty {
            if let nearest = (readers[id] ?? []).map({ column[$0.to]! }).min() { column[id] = max(0, nearest - 1) }
        }

        let columnCount = (column.values.max() ?? -1) + 1
        var layers: [[Int]] = Array(repeating: [], count: columnCount)
        for id in topological where wired.contains(id) { layers[column[id]!].append(id) }

        // 3. Barycentre sweeps, alternating direction.
        func place(_ layer: [Int], by neighbours: (Int) -> [Int], of reference: [Int]) -> [Int] {
            let index = Dictionary(reference.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { a, _ in a })
            let keyed = layer.enumerated().map { position, id -> (Double, Int, Int) in
                let known = neighbours(id).compactMap { index[$0] }
                // A block with no neighbour there keeps its place.
                let centre = known.isEmpty ? Double(position) : known.reduce(0, +) / Double(known.count)
                return (centre, position, id)
            }
            return keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        }
        for _ in 0..<4 {
            for c in layers.indices.dropFirst() {
                layers[c] = place(layers[c], by: { (feeders[$0] ?? []).map(\.from) }, of: layers[c - 1])
            }
            for c in layers.indices.dropLast().reversed() {
                layers[c] = place(layers[c], by: { (readers[$0] ?? []).map(\.to) }, of: layers[c + 1])
            }
        }

        // 4. Coordinates.
        var x: [CGFloat] = []
        var cursor = origin.x
        for layer in layers {
            x.append(cursor)
            cursor += (layer.map { byId[$0]!.size.width }.max() ?? 0) + columnGap
        }
        var y: [Int: CGFloat] = [:]
        /// Stacks a column top to bottom, each block at its wish or just below the one above.
        func pack(_ layer: [Int], wish: (Int) -> CGFloat?) {
            var bottom = -CGFloat.infinity
            for id in layer {
                let top = max(wish(id) ?? bottom + rowGap, bottom + rowGap)
                y[id] = top.isFinite ? top : origin.y
                bottom = y[id]! + byId[id]!.size.height
            }
        }
        /// Where a block's top goes for its pins to be level with the pins at the other end of `wires`.
        func aligned(_ wires: [Edge], other: (Edge) -> Int, otherPin: (Edge) -> CGFloat?,
                     ownPin: (Edge) -> CGFloat?) -> CGFloat? {
            let wishes = wires.compactMap { wire -> CGFloat? in
                guard let top = y[other(wire)], let theirs = otherPin(wire), let mine = ownPin(wire) else { return nil }
                return top + theirs - mine
            }
            return wishes.isEmpty ? nil : wishes.reduce(0, +) / CGFloat(wishes.count)
        }
        for layer in layers {
            pack(layer) { aligned(feeders[$0] ?? [], other: \.from, otherPin: \.fromPinY, ownPin: \.toPinY) }
        }
        // Sources had nothing to line up with on the way right; line them up with what they feed.
        for layer in layers.reversed() where layer.contains(where: { (feeders[$0] ?? []).isEmpty }) {
            pack(layer) { id in
                (feeders[id] ?? []).isEmpty
                    ? aligned(readers[id] ?? [], other: \.to, otherPin: \.toPinY, ownPin: \.fromPinY)
                    : y[id]
            }
        }

        var result: [Int: CGPoint] = [:]
        for (c, layer) in layers.enumerated() {
            for id in layer { result[id] = CGPoint(x: x[c], y: y[id]!) }
        }
        // Keep the top edge where the page's was: the alignment may have pushed everything down (or up).
        let top = result.values.map(\.y).min() ?? origin.y
        for id in result.keys { result[id]!.y += origin.y - top }

        // Unwired blocks: rows below, wrapping at the width of the rest.
        let width = max(cursor - columnGap - origin.x, 600)
        var rowX = origin.x, rowY = (result.map { $0.value.y + byId[$0.key]!.size.height }.max() ?? origin.y - rowGap)
            + rowGap * 2, rowHeight: CGFloat = 0
        for node in nodes where !wired.contains(node.id) {
            if rowX > origin.x, rowX + node.size.width > origin.x + width {
                rowX = origin.x
                rowY += rowHeight + rowGap
                rowHeight = 0
            }
            result[node.id] = CGPoint(x: rowX, y: rowY)
            rowX += node.size.width + rowGap
            rowHeight = max(rowHeight, node.size.height)
        }
        return result
    }
}
