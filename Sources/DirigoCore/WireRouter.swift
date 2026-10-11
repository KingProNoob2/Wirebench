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
/// and only a corridor that clears every block is used.
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
    public static func route(
        from src: CGPoint,
        to dst: CGPoint,
        lane: Double = 0,
        obstacles: [CGRect] = [],
        clearAbove: Double? = nil,
        clearBelow: Double = 0
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

    /// Replaces each sharp corner of a routed polyline with a short quadratic arc.
    ///
    /// Right angles on their own read as a tangle; rounding them is most of what makes a dense
    /// schematic legible.
    public static func roundedPath(_ points: [CGPoint], radius: CGFloat = 7) -> CGPath {
        let path = CGMutablePath()
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
