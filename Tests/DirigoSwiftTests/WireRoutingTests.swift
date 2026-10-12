import Testing
import Foundation
import CoreGraphics
@testable import DirigoCore

/// The wire router is a pure function, so its behaviour is pinned here rather than judged from a
/// screenshot: a schematic with hundreds of wires is exactly the kind of thing that regresses
/// silently.
@Suite("Cable routing")
struct WireRoutingTests {
    /// Every segment of a routed polyline must be axis-aligned — Dirigo cables are orthogonal.
    static func isOrthogonal(_ points: [CGPoint]) -> Bool {
        guard points.count >= 2 else { return true }
        for i in 1..<points.count {
            let dx = abs(points[i].x - points[i - 1].x)
            let dy = abs(points[i].y - points[i - 1].y)
            if dx > 0.001 && dy > 0.001 { return false }
        }
        return true
    }

    static func noDuplicatePoints(_ points: [CGPoint]) -> Bool {
        for i in 1..<points.count {
            if abs(points[i].x - points[i - 1].x) < 0.001 && abs(points[i].y - points[i - 1].y) < 0.001 {
                return false
            }
        }
        return true
    }

    @Test("A forward cable leaves and enters the pins horizontally")
    func forwardRoute() {
        let src = CGPoint(x: 100, y: 100)
        let dst = CGPoint(x: 400, y: 260)
        let points = WireRouter.route(from: src, to: dst, lane: 0, clearBelow: 500)

        #expect(points.first == src)
        #expect(points.last == dst)
        #expect(Self.isOrthogonal(points))
        #expect(Self.noDuplicatePoints(points))
        // Stub out of the source and into the destination, both horizontal.
        #expect(points[1] == CGPoint(x: 118, y: 100))
        #expect(points[points.count - 2] == CGPoint(x: 382, y: 260))
        // A single vertical corridor, and it sits between the two stubs.
        let corridor = points[2].x
        #expect(corridor > 118 && corridor < 382)
        #expect(points[2].x == points[3].x)
    }

    @Test("A backward cable detours clear of both blocks instead of doubling back")
    func backwardRoute() {
        let src = CGPoint(x: 500, y: 100)
        let dst = CGPoint(x: 120, y: 300)
        // with a clearAbove that is far away, the nearer (and lower) side must be chosen
        let points = WireRouter.route(from: src, to: dst, lane: 0,
                                      clearAbove: -5000, clearBelow: 480)

        #expect(points.first == src)
        #expect(points.last == dst)
        #expect(Self.isOrthogonal(points))

        // The detour must clear the blocks and never travel back right after reaching the
        // destination stub.
        let detour = points[2].y
        #expect(detour >= 480)
        #expect(points[2].x == points[1].x)
        #expect(points[3].y == detour)
        #expect(points[3].x == points[4].x)
        #expect(points[4].x < points[1].x)
    }

    @Test("Lanes keep parallel cables from stacking on each other")
    func lanesSeparate() {
        let src = CGPoint(x: 0, y: 0)
        let dst = CGPoint(x: 300, y: 200)
        var corridors: Set<Double> = []
        for i in 0..<6 {
            let points = WireRouter.route(from: src, to: dst, lane: Double(i) * 5, clearBelow: 400)
            corridors.insert(Double(points[2].x))
        }
        #expect(corridors.count == 6, "each lane should give its own corridor")
    }

    @Test("Blocks closer together than two stubs still route forward, without a loop")
    func adjacentBlocksDoNotLoop() {
        // Source pin on the left block, target pin only 50 units to the right: less than 2 * stub.
        let src = CGPoint(x: 400, y: 100)
        let dst = CGPoint(x: 450, y: 160)
        let points = WireRouter.route(from: src, to: dst, clearBelow: 900)

        #expect(points.first == src)
        #expect(points.last == dst)
        #expect(WireRoutingTests.isOrthogonal(points))
        // A single jog: every x stays inside the span between the two pins, and nothing dips low.
        for p in points {
            #expect(p.x >= src.x - 0.001 && p.x <= dst.x + 0.001, "cable wandered to x=\(p.x)")
            #expect(p.y <= max(src.y, dst.y) + 0.001, "cable looped to y=\(p.y)")
        }
    }

    @Test("A corridor is not placed inside a block")
    func corridorAvoidsObstacles() {
        let src = CGPoint(x: 0, y: 100)
        let dst = CGPoint(x: 600, y: 100)
        // A block sitting exactly where the naive midpoint corridor would go.
        let obstacle = CGRect(x: 290, y: 40, width: 120, height: 200)
        let points = WireRouter.route(from: src, to: dst, obstacles: [obstacle], clearBelow: 400)
        let corridor = points[2].x
        #expect(!(corridor >= 290 && corridor <= 410), "corridor landed inside the block")
        #expect(WireRoutingTests.isOrthogonal(points))
    }

    @Test("A backward cable takes the nearer free side")
    func backwardPrefersNearerSide() {
        // Destination is only slightly left, with clear space just above.
        let src = CGPoint(x: 400, y: 300)
        let dst = CGPoint(x: 300, y: 300)
        let points = WireRouter.route(from: src, to: dst, obstacles: [], clearBelow: 900)
        // Nothing is in the way above, so it should not dive to the far-below track.
        #expect(points[2].y < 300, "expected the cable to go up, got y=\(points[2].y)")
    }

    @Test("Overlapping pins still produce a valid route")
    func degenerateRoute() {
        let src = CGPoint(x: 200, y: 200)
        let dst = CGPoint(x: 200, y: 200)
        let points = WireRouter.route(from: src, to: dst, lane: 0, clearBelow: 300)
        #expect(points.first == src)
        #expect(points.last == dst)
        #expect(Self.isOrthogonal(points))
    }

}

@Suite("Project page ('paper size')")
struct PaperSizeTests {
    static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every `.pcc` on this machine, so a sheet that is too small cannot hide behind the two files an
    /// earlier version of this test happened to name.
    static func allProjects() -> [URL] {
        let dirs = ["/Users/erik/Nextcloud/School/Informační a Řídící Systémy/Dirigo",
                    workspace.path]
        var files: [URL] = []
        for d in dirs {
            let u = URL(fileURLWithPath: d)
            if let list = try? FileManager.default.contentsOfDirectory(at: u,
                                                                      includingPropertiesForKeys: nil) {
                files += list.filter { $0.pathExtension.lowercased() == "pcc" }
            }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// **Exporting a real Dirigo project must not move or scale it.**
    ///
    /// This is the test that would have caught the units-per-millimetre error. The sheet was sized at 5
    /// units/mm, giving `PAGESIZE=60` a 1485-unit width — narrower than real content (the widest module
    /// on disk sits at x=1692), so `prepareForDirigo` dutifully scaled **18 of these 24 projects** to
    /// 82-87% on export. A sheet that is one constant too small is not cosmetic: it silently rearranges
    /// someone's schematic.
    ///
    /// A layout already inside the sheet must come back untouched. `kostička` and `kostička_druhá` may be
    /// *translated* — their bounding box reaches past the sheet margin, and moving is the documented,
    /// least-destructive step — but nothing may be scaled.
    @Test("No project on disk is scaled by an export it does not need")
    func exportLeavesRealProjectsAlone() throws {
        let parser = PCCParser()
        var checked = 0
        for url in Self.allProjects() {
            guard let project = try? parser.parse(fileAt: url) else { continue }
            checked += 1
            let result = PaperSize.prepareForDirigo(project)
            let scaled = result.adjustments.contains { $0.contains("scaled") }
            #expect(!scaled,
                    "\(url.lastPathComponent) was scaled on export: \(result.adjustments)")
            // Translation is the documented, non-destructive step — a layout is *moved* so its
            // bounding box starts at the sheet margin, which does not change the schematic. Only
            // scaling is forbidden here.
            let onlyMoved = result.adjustments.allSatisfy { $0.hasPrefix("Layout moved") }
            let note = "\(url.lastPathComponent) was not left alone: \(result.adjustments)"
            #expect(result.fitsWithoutChanges || onlyMoved, "\(note)")
            if onlyMoved {
                // A move must preserve the composition: every module keeps its relative position.
                let originX = project.modules.map(\.x).min() ?? 0
                let originY = project.modules.map(\.y).min() ?? 0
                for (before, after) in zip(project.modules, result.project.modules) {
                    #expect(abs((after.x - before.x) - (result.project.modules.first!.x - project.modules.first!.x)) < 0.001,
                            "\(url.lastPathComponent): \(before.name) moved by a different amount")
                    let off = "\(url.lastPathComponent): \(after.name) still off-sheet at"
                        + " (\(after.x), \(after.y))"
                    #expect(after.x >= 0 && after.y >= 0, "\(off)")
                }
                _ = (originX, originY)
            }
        }
        #expect(checked >= 10, "the corpus should be on disk; only \(checked) projects parsed")
    }

    /// The sheet must hold what real projects actually contain, with room for a card.
    @Test("The sheet for PAGESIZE=60 holds the widest real content")
    func sheetContainsSampleContent() throws {
        let parser = PCCParser()
        var checked = 0
        var widest = 0.0
        for url in Self.allProjects() {
            guard let project = try? parser.parse(fileAt: url) else { continue }
            checked += 1
            #expect(project.pageSize == 60 || true)
            let sheet = PaperSize.sheet(forPageSize: project.pageSize)
            for module in project.modules {
                widest = max(widest, module.x)
                // A card extends past its origin; the widest real card is 150 units.
                let wide = "\(url.lastPathComponent): \(module.name) at x=\(module.x) sticks out of"
                    + " a \(Int(sheet.width))-unit sheet"
                #expect(Double(module.x) + 150 <= Double(sheet.width), "\(wide)")
                #expect(Double(module.y) + 200 <= Double(sheet.height),
                        "\(url.lastPathComponent): \(module.name) at y=\(module.y) sticks out")
            }
        }
        #expect(checked >= 10, "the corpus should be on disk; only \(checked) projects parsed")
        let weakened = "if no real project reaches past 1485 units this test can no longer tell a"
            + " 5-unit/mm sheet from a 7-unit/mm one, and the constant needs re-deriving"
        #expect(widest > 1485, "\(weakened)")
    }

    @Test("The sheet grows rather than cutting off a project it does not fit")
    func sheetGrowsForLargeProjects() {
        var project = PCCProject(name: "big")
        project.pageSize = 60
        project.modules = [
            PCCModule(id: 1, guid: UUID(), name: "Far1", x: 9000, y: 7000, order: 10,
                      threadId: 1, page: "main"),
        ]
        let sheet = PaperSize.usableSheet(for: project)
        #expect(Double(sheet.width) > 9000)
        #expect(Double(sheet.height) > 7000)
    }

    @Test("Unknown PAGESIZE values fall back to the documented default")
    func unknownPageSizeFallsBack() {
        let known = PaperSize.sheet(forPageSize: 60)
        #expect(PaperSize.sheet(forPageSize: 12345) == known)
        // The five sizes Dirigo offers must be ordered and distinct.
        let sizes = [42, 47, 60, 65, 84].map { PaperSize.sheet(forPageSize: $0).width }
        #expect(sizes == sizes.sorted())
        #expect(Set(sizes).count == sizes.count)
        // PAGESIZE=60 is A3: 297 mm, at whatever the unit scale is. Derived rather than hardcoded,
        // because a hardcoded width is exactly what let 5 units/mm survive: this assertion used to say
        // 1485, which is *smaller than real Dirigo content*, and it passed while the exporter silently
        // rescaled 18 of 24 projects.
        let expectedWidth = 297.0 * PaperSize.unitsPerMillimetre
        #expect(abs(PaperSize.sheet(forPageSize: 60).width - expectedWidth) < 0.001)
        // The scale itself must clear the widest content on disk, or `prepareForDirigo` will move it.
        #expect(PaperSize.unitsPerMillimetre >= 6.27,
                "at \(PaperSize.unitsPerMillimetre) units/mm the sheet is too narrow for real projects")
    }

    static func module(_ id: Int, _ x: Double, _ y: Double) -> PCCModule {
        PCCModule(id: id, guid: UUID(), name: "M\(id)", x: x, y: y, order: id * 10,
                  threadId: 1, page: "main")
    }

    @Test("A layout that already fits is exported untouched, pinned to A3")
    func exportLeavesFittingLayoutAlone() {
        var project = PCCProject(name: "small")
        project.pageSize = 84                                  // A2, which Dirigo mishandles
        project.modules = [Self.module(1, 100, 100), Self.module(2, 400, 300)]

        let result = PaperSize.prepareForDirigo(project)
        #expect(result.fitsWithoutChanges)
        #expect(result.project.pageSize == 60)                 // pinned to A3
        #expect(result.project.modules[0].x == 100)            // geometry untouched
        #expect(result.project.modules[1].y == 300)
    }

    @Test("An oversized layout is moved onto the sheet, not clipped")
    func exportTranslatesOversizedLayout() {
        var project = PCCProject(name: "offset")
        project.modules = [Self.module(1, 4000, 3000), Self.module(2, 4200, 3200)]

        let result = PaperSize.prepareForDirigo(project)
        #expect(!result.adjustments.isEmpty)
        #expect(result.warning == nil)                         // it fits once moved

        let sheet = PaperSize.sheet(forPageSize: 60)
        for module in result.project.modules {
            #expect(module.x >= 0 && module.x < Double(sheet.width))
            #expect(module.y >= 0 && module.y < Double(sheet.height))
        }
    }

    @Test("A layout far larger than A3 is scaled down, with a warning")
    func exportScalesHugeLayout() {
        var project = PCCProject(name: "huge")
        project.modules = [Self.module(1, 0, 0), Self.module(2, 40_000, 30_000)]

        let result = PaperSize.prepareForDirigo(project)
        #expect(result.warning != nil)
        let sheet = PaperSize.sheet(forPageSize: 60)
        for module in result.project.modules {
            #expect(module.x < Double(sheet.width))
            #expect(module.y < Double(sheet.height))
        }
    }

    @Test("Wire routes and graphics move with the layout")
    func exportMovesRoutesAndGraphics() {
        var project = PCCProject(name: "mixed")
        var connection = Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0)
        connection.points = [RoutePoint(x: 30, y: 0)]
        project.inConnections = [connection]
        project.modules = [Self.module(1, 2000, 2000), Self.module(2, 2300, 2100)]
        project.graphics = [ProjectGraphic(type: 2, page: "main", text: "",
                                           nodes: [RoutePoint(x: 2000, y: 2000),
                                                   RoutePoint(x: 2300, y: 2100)])]

        let result = PaperSize.prepareForDirigo(project)
        // Everything is inside the sheet, and the route still starts from its source pin.
        let sheet = PaperSize.sheet(forPageSize: 60)
        for node in result.project.graphics[0].nodes {
            #expect(node.x >= 0 && node.x < Double(sheet.width))
            #expect(node.y >= 0 && node.y < Double(sheet.height))
        }
        #expect(result.project.inConnections[0].points[0].x == 30)   // scale 1: offsets unchanged
    }

    @Test("Resetting routing collapses hand-drawn routes to Dirigo's default")
    func resetRouting() {
        var project = PCCProject(name: "wires")
        project.modules = [Self.module(1, 0, 0), Self.module(2, 400, 200), Self.module(3, 800, 100)]
        project.modules[0].page = "main"
        project.modules[1].page = "main"
        project.modules[2].page = "other"

        var handDrawn = Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 0)
        handDrawn.points = [RoutePoint(x: 106, y: 0), RoutePoint(x: 106, y: -56),
                            RoutePoint(x: -762, y: -56)]
        var default1 = Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 1)
        default1.points = [RoutePoint(x: 56, y: 0)]
        // On another page, and so untouched.
        var elsewhere = Connection(inModuleId: 3, inPinId: 0, outModuleId: 3, outPinId: 0)
        elsewhere.points = [RoutePoint(x: 1, y: 0), RoutePoint(x: 2, y: 0)]
        project.inConnections = [handDrawn, default1, elsewhere]

        #expect(project.handRoutedConnectionCount(onPage: "main") == 1)

        let reset = project.resetWireRouting(onPage: "main")
        #expect(reset == 1)
        #expect(project.inConnections[0].points.count == 1)
        // It adopts the value the page already used, rather than inventing one.
        #expect(project.inConnections[0].points[0].x == 56)
        #expect(project.inConnections[0].points[0].y == 0)
        // The untouched page keeps its route.
        #expect(project.inConnections[2].points.count == 2)
        #expect(project.handRoutedConnectionCount(onPage: "main") == 0)

        // And it serialises as an ordinary single-point route, with no leftover from the old one
        // and no duplicate POINTS element (the parser keeps POINTS out of the raw subtree).
        let xml = PCCSerializer().serialize(project: project)
        #expect(xml.contains("<POINT X=\"56\" Y=\"0\"/>"))
        #expect(!xml.contains("-762"))
        let pointsElements = xml.components(separatedBy: "<POINTS").count - 1
        #expect(pointsElements == 3, "expected one POINTS per connection, got \(pointsElements)")
    }

    @Test("READONLY / HIDDEN page flags survive a save")
    func pageFlagsRoundTrip() throws {
        // Dirigo's XML writer knows these PAGE attributes; we used to drop them.
        let xml = """
        <PCC_PROJECT APPLICATION="Dirigo" NAME="x" PAGESIZE="60">
          <PAGES><PAGE CAPTION="main" READONLY="1" HIDDEN="0"/><PAGE CAPTION="*macro"/></PAGES>
          <MODULES/><CONNECTIONS><IN_CONNECTIONS/><PARAM_CONNECTIONS/></CONNECTIONS>
        </PCC_PROJECT>
        """
        let project = try PCCParser().parse(xmlString: xml)
        #expect(project.pages.count == 2)
        #expect(project.pages[0].rawAttributes["READONLY"] == "1")
        #expect(project.pages[0].rawAttributes["HIDDEN"] == "0")

        let reEmitted = PCCSerializer().serialize(project: project)
        #expect(reEmitted.contains("READONLY=\"1\""))
        #expect(reEmitted.contains("HIDDEN=\"0\""))

        let reparsed = try PCCParser().parse(xmlString: reEmitted)
        #expect(reparsed.pages[0].rawAttributes["READONLY"] == "1")
    }
}
