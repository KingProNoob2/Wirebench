import Foundation

/// Routed wire paths, kept for as long as the sheet's geometry is unchanged.
///
/// A reference type on purpose: it lives in `@State` so it survives a body evaluation, and filling it
/// during `body` does not invalidate anything — it is not observable state, just a cache.
@MainActor
package final class WireRouteCache {
    package init() {}

    private var key: Int?
    private var routes: [String: [CGPoint]] = [:]
    /// The last path routed for each cable, which survives `beginFrame`. A cable that is holding still
    /// through a drag does not overwrite it, so the held path stays the one it was checked against.
    private var settled: [String: [CGPoint]] = [:]
    /// Whether the previous frame was drawn mid-drag, so the frame a drag ends on can be told apart
    /// from a frame where the sheet itself changed.
    private var lastFrameWasDrag = false
    /// The quantised geometry each held interior was routed for; see `points(for:holdSettled:signature:)`.
    private var anchors: [String: (signature: Int, path: [CGPoint])] = [:]

    /// Number of paths actually computed, for tests and for anyone profiling this later.
    private(set) var routeCount = 0

    /// Starts a frame, saying whether a drag is in progress or has just ended.
    ///
    /// `settled` is what a cable holds while something else is dragged, and it is cleared when the
    /// *idle* geometry changes — an edit, a reset, a load — because then every route is worth
    /// recomputing. It is **not** cleared when a drag ends: the routes drawn during the drag are the
    /// routes that stay, and clearing here is what made a wire jump the moment the mouse was released.
    package func beginFrame(key: Int, dragging: Bool) {
        let dragJustEnded = lastFrameWasDrag && !dragging
        lastFrameWasDrag = dragging
        guard self.key != key else { return }
        self.key = key
        routes.removeAll()
        if !dragging && !dragJustEnded { settled.removeAll(); anchors.removeAll() }
    }

    /// The path a cable last settled on, so a drag of some *other* block can hold it — and check
    /// whether it is still clear of what moved — instead of recomputing it every frame.
    package func settledPoints(for id: String) -> [CGPoint]? { settled[id] }

    /// - Parameters:
    ///   - holdSettled: reuse the cable's last settled path instead of routing it again. For
    ///     cables a drag does not move, so they hold still while it lasts.
    ///   - temporary: this route is only being used because *something else* is in the way — another
    ///     block being dragged over the cable. It is drawn, but not kept: a cable pushed aside by a
    ///     drag has to come back to the route it had, not settle into the detour. Without this a wire
    ///     stayed crooked after the block that had crossed it moved on.
    ///   - signature: the cable's geometry quantised to `WireRouter.pitch`. While it holds, the cable
    ///     keeps the *interior* of its last route and only its two ends follow the pins — the dead zone
    ///     that stops a small drag from making the wire swim left and right. `nil` opts out, for a
    ///     connection whose stored `POINTS` are followed verbatim and move with their pins anyway.
    ///   - src, dst: the true pin positions, for re-anchoring a held interior.
    package func points(for id: String, holdSettled: Bool = false, temporary: Bool = false,
                signature: Int? = nil,
                src: CGPoint = .zero, dst: CGPoint = .zero, _ build: () -> [CGPoint]) -> [CGPoint] {
        if let cached = routes[id] { return cached }
        if holdSettled, let held = settled[id] {
            routes[id] = held
            return held
        }
        if let signature, let anchor = anchors[id], anchor.signature == signature,
           let held = Self.reanchored(anchor.path, src: src, dst: dst) {
            routes[id] = held
            return held
        }
        let made = build()
        routes[id] = made
        if !holdSettled && !temporary {
            settled[id] = made
            if let signature { anchors[id] = (signature, made) }
        }
        routeCount += 1
        return made
    }

    /// Puts a held path's ends back on the pins they now belong to and leaves the interior alone.
    ///
    /// The runs beside the ends are the pins' own stubs, so rewriting the leading horizontal run and
    /// the trailing one keeps every segment axis-aligned. Returns nil for a path that has no such
    /// structure — a straight same-row run, or one with fewer than four points — where re-anchoring
    /// would bend the wire rather than move it; the caller routes those afresh.
    private static func reanchored(_ path: [CGPoint], src: CGPoint, dst: CGPoint) -> [CGPoint]? {
        guard path.count >= 4 else { return nil }
        let oldSrcY = path[0].y, oldDstY = path[path.count - 1].y
        guard oldSrcY != oldDstY,
              path[0].y == path[1].y, path[path.count - 2].y == path[path.count - 1].y else { return nil }

        var out = path
        var head = 0
        while head < out.count, out[head].y == oldSrcY { out[head].y = src.y; head += 1 }
        var tail = out.count - 1
        while tail >= 0, out[tail].y == oldDstY { out[tail].y = dst.y; tail -= 1 }
        out[0] = src
        out[out.count - 1] = dst
        return out
    }
}
