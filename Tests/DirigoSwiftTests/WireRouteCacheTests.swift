import Testing
import Foundation
import CoreGraphics
@testable import DirigoApp

/// Cable routing is a path search around the sheet's obstacles, and it depends only on geometry — module
/// positions, drag offsets, and a connection's own stored points. It never depends on a signal value, so
/// re-running it in `body` meant every tick re-routed every cable: a profile of the app put 3.99 s of
/// 4.40 s on the main thread against 5 ms in SwiftUI's renderer, and this is where that time was.
@Suite("Wire route cache")
@MainActor
struct WireRouteCacheTests {
    @Test("A path is computed once, then reused while the geometry holds")
    func reusesWithinAFrame() {
        let cache = WireRouteCache()
        var builds = 0
        func path() -> [CGPoint] { builds += 1; return [.zero, CGPoint(x: 10, y: 10)] }

        cache.beginFrame(key: 1)
        _ = cache.points(for: "a", path)
        _ = cache.points(for: "b", path)
        _ = cache.points(for: "a", path)

        #expect(builds == 2, "one build per cable, not one per read")
        #expect(cache.routeCount == 2)
    }

    @Test("A new geometry routes again")
    func invalidatesOnGeometryChange() {
        let cache = WireRouteCache()
        var builds = 0
        func path() -> [CGPoint] { builds += 1; return [.zero] }

        cache.beginFrame(key: 1)
        _ = cache.points(for: "a", path)
        cache.beginFrame(key: 1)
        _ = cache.points(for: "a", path)
        #expect(builds == 1, "same geometry: the cached path stands")

        cache.beginFrame(key: 2)
        _ = cache.points(for: "a", path)
        #expect(builds == 2, "moved blocks must re-route")
    }

    @Test("Every cable on the canvas is cached, not just the first")
    func cachesEachCable() {
        let cache = WireRouteCache()
        var builds = 0
        cache.beginFrame(key: 7)
        for index in 0..<20 {
            _ = cache.points(for: "cable\(index)") { builds += 1; return [.zero] }
        }
        #expect(builds == 20)
        // A second pass over the same geometry builds nothing.
        cache.beginFrame(key: 7)
        for index in 0..<20 {
            _ = cache.points(for: "cable\(index)") { builds += 1; return [.zero] }
        }
        #expect(builds == 20)
    }
}
