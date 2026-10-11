import Testing
import Foundation
import CoreGraphics
import DirigoCore
@testable import DirigoApp

/// Geometry that only the GUI used to exercise — and where a coordinate-space mistake is invisible
/// until a user drags a wire and nothing happens. `PinHitTest` compares against the card's pin
/// points, which are in *content* coordinates, while a gesture reports *viewport* coordinates
/// (after zoom and pan), so the conversion between the two is exactly the kind of thing that must
/// be tested rather than eyeballed.
@Suite("Canvas geometry")
struct CanvasGeometryTests {
    static func module(_ id: Int, x: Double, y: Double, inPins: Int, outPins: Int) -> PCCModule {
        PCCModule(id: id, guid: UUID(), name: "M\(id)", x: x, y: y, order: id * 10,
                  threadId: 1, page: "main",
                  inPins: (0..<inPins).map { Pin(id: $0, value: .int32(0)) },
                  outPins: (0..<outPins).map { Pin(id: $0, value: .int32(0)) })
    }

    @Test("A pin is found at its own centre, and not far from it")
    func hitTestTolerance() {
        let module = Self.module(1, x: 100, y: 100, inPins: 2, outPins: 1)
        var project = PCCProject(name: "geometry")
        project.modules = [module]
        let ids: Set<Int> = [1]

        let centre = ModuleCardView.inPinPoint(for: module, pinIndex: 0)
        let found = PinHitTest.pin(at: centre, in: project, pageModuleIds: ids)
        #expect(found == PinReference(moduleId: 1, side: .input, index: 0))

        // Pin rows are 16 pt apart and the band is 6 pt either side of a row's centre, so the
        // 8 pt midpoint between two rows is outside both. (14 pt would be only 2 pt from the *next*
        // row, which is a legitimate hit — that distinction is what this test pins down.)
        let between = CGPoint(x: centre.x, y: centre.y + 8)
        #expect(PinHitTest.pin(at: between, in: project, pageModuleIds: ids) == nil,
                "the midpoint between two pin rows must not grab either")

        // The bead is drawn inside the card, about 10 pt in from the anchor on the edge. Aiming at
        // the bead — which is what a user does — must count as hitting the pin. This is the case a
        // circle around the anchor missed.
        let bead = CGPoint(x: centre.x + 10, y: centre.y)
        #expect(PinHitTest.pin(at: bead, in: project, pageModuleIds: ids)
                == PinReference(moduleId: 1, side: .input, index: 0),
                "the visible bead must be grabbable, not just the anchor point")

        let output = ModuleCardView.outPinPoint(for: module, pinIndex: 0)
        let outFound = PinHitTest.pin(at: output, in: project, pageModuleIds: ids)
        #expect(outFound == PinReference(moduleId: 1, side: .output, index: 0))
        // The output bead is likewise drawn inside the card, to the left of the anchor.
        let outBead = CGPoint(x: output.x - 10, y: output.y)
        #expect(PinHitTest.pin(at: outBead, in: project, pageModuleIds: ids)
                == PinReference(moduleId: 1, side: .output, index: 0))
    }

    @Test("A module on another page is not a hit target")
    func otherPagesAreExcluded() {
        let module = Self.module(1, x: 0, y: 0, inPins: 1, outPins: 0)
        var project = PCCProject(name: "geometry")
        project.modules = [module]
        let centre = ModuleCardView.inPinPoint(for: module, pinIndex: 0)
        #expect(PinHitTest.pin(at: centre, in: project, pageModuleIds: []) == nil)
    }

    @Test("Wiring only accepts an input/output pair, and commits it")
    func connectThroughTheModel() {
        let source = Self.module(1, x: 0, y: 0, inPins: 0, outPins: 1)
        let sink = Self.module(2, x: 300, y: 0, inPins: 1, outPins: 0)
        var project = PCCProject(name: "geometry")
        project.modules = [source, sink]

        let model = AppModel()
        model.project = project

        // Two inputs, or two outputs, are not a wire.
        #expect(!model.connectPins(from: PinReference(moduleId: 1, side: .output, index: 0),
                                   to: PinReference(moduleId: 2, side: .output, index: 0)))
        #expect(model.project?.inConnections.isEmpty == true)

        // An output to an input is, in either drag direction.
        let connected = model.connectPins(from: PinReference(moduleId: 2, side: .input, index: 0),
                                          to: PinReference(moduleId: 1, side: .output, index: 0))
        #expect(connected)
        #expect(model.project?.inConnections.count == 1)
        #expect(model.project?.connection(inModuleId: 2, inPinId: 0)?.outModuleId == 1)

        // And it is undoable, because it goes through the `project` setter.
        #expect(model.canUndo)
    }
}

@Suite("Canvas transform")
struct CanvasTransformTests {
    @Test("Viewport and content conversions are inverses")
    func roundTrip() {
        let zoom: CGFloat = 2.5
        let pan = CGSize(width: -340, height: 87)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 123.5, y: -47.25), CGPoint(x: 1000, y: 800)] {
            let viewport = CanvasTransform.viewportPoint(from: point, zoom: zoom, pan: pan)
            let back = CanvasTransform.contentPoint(from: viewport, zoom: zoom, pan: pan)
            #expect(abs(back.x - point.x) < 0.0001 && abs(back.y - point.y) < 0.0001)
        }
    }

    @Test("A pin stays hittable when the canvas is zoomed and panned")
    func hitTestSurvivesTransform() {
        // This is the bug that shipped: hit-testing used viewport coordinates against content-space
        // pin geometry, so a drop only ever matched at 100% zoom with no pan.
        let module = PCCModule(id: 1, guid: UUID(), name: "M1", x: 200, y: 150, order: 10,
                               threadId: 1, page: "main",
                               inPins: [Pin(id: 0, value: .int32(0))], outPins: [])
        var project = PCCProject(name: "transform")
        project.modules = [module]

        let zoom: CGFloat = 3
        let pan = CGSize(width: -120, height: 45)
        let pin = ModuleCardView.inPinPoint(for: module, pinIndex: 0)

        // What the gesture would report, given the canvas transform.
        let asGestureWouldReport = CanvasTransform.viewportPoint(from: pin, zoom: zoom, pan: pan)
        let recovered = CanvasTransform.contentPoint(from: asGestureWouldReport, zoom: zoom, pan: pan)
        #expect(PinHitTest.pin(at: recovered, in: project, pageModuleIds: [1])
                == PinReference(moduleId: 1, side: .input, index: 0))

        // And feeding the raw viewport point straight in must fail, which is what a missing
        // conversion looks like.
        #expect(PinHitTest.pin(at: asGestureWouldReport, in: project, pageModuleIds: [1]) == nil,
                "without the conversion the hit test misses — the original defect")
    }
}
