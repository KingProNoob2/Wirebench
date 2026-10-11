import SwiftUI
import DirigoCore

/// One end of a wire.
///
/// The original wires **input to output** and nothing else (`GrafickeOkno.html`), so a reference
/// always names a side; the rules themselves live in `PCCProject.connect` where they are testable.
public enum PinSide: Equatable, Sendable {
    case input
    case output
}

public struct PinReference: Equatable, Sendable {
    public let moduleId: Int
    public let side: PinSide
    public let index: Int

    public init(moduleId: Int, side: PinSide, index: Int) {
        self.moduleId = moduleId
        self.side = side
        self.index = index
    }
}

/// A wire being dragged: where it started, and where the pointer is now.
public struct PendingWire: Equatable {
    public var from: PinReference
    public var point: CGPoint

    public init(from: PinReference, point: CGPoint) {
        self.from = from
        self.point = point
    }
}

/// Finds the pin under a point in canvas coordinates.
///
/// The card's own geometry is the single source of truth here — `inPinPoint`/`outPinPoint` are what
/// the wire router already draws with, so hit-testing cannot drift away from what is on screen.
public enum PinHitTest {
    /// Vertical half-height of a pin's hit band. Pin rows are 16 pt apart, so this must stay below
    /// 8 or a point between two rows would be equidistant from both.
    public static let verticalTolerance: CGFloat = 6

    /// Horizontal reach of a pin's hit band, measured from the pin's anchor on the card edge.
    ///
    /// A circle around the anchor does not work: the pin *bead* is drawn inside the card (the pin
    /// area is padded 6 pt, so the bead's centre sits about 10 pt in) and a user aims at the bead.
    /// A circle small enough to avoid the neighbouring row was therefore too small to cover the
    /// bead at all, which is one reason dragging a wire did nothing.
    public static let horizontalReach: CGFloat = 14

    public static func pin(at point: CGPoint, in project: PCCProject,
                           pageModuleIds: Set<Int>) -> PinReference? {
        var best: (reference: PinReference, distance: CGFloat)?

        func consider(_ reference: PinReference, _ candidate: CGPoint) {
            // A band over the whole pin row: generous along the row (so the bead and the edge it
            // attaches to are both grabbable), tight across it (so rows never overlap).
            let dx = abs(point.x - candidate.x)
            let dy = abs(point.y - candidate.y)
            guard dx <= horizontalReach, dy <= verticalTolerance else { return }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (reference, distance)
            }
        }

        for module in project.modules where pageModuleIds.contains(module.id) {
            for index in 0..<module.inPins.count {
                consider(PinReference(moduleId: module.id, side: .input, index: index),
                         ModuleCardView.inPinPoint(for: module, pinIndex: index))
            }
            for index in 0..<module.outPins.count {
                consider(PinReference(moduleId: module.id, side: .output, index: index),
                         ModuleCardView.outPinPoint(for: module, pinIndex: index))
            }
        }
        return best?.reference
    }
}

// MARK: - Committing a wire

extension AppModel {
    /// Connects two pins, whichever order the drag ran in.
    ///
    /// Returns false when the pair is not a valid input/output pair or the project refused it. The
    /// `project` setter is the single undo choke point, so the wire is undoable for free.
    @discardableResult
    public func connectPins(from: PinReference, to: PinReference) -> Bool {
        guard from.moduleId != to.moduleId else { return false }

        let output: PinReference
        let input: PinReference
        switch (from.side, to.side) {
        case (.output, .input): output = from; input = to
        case (.input, .output): output = to; input = from
        default: return false          // input-to-input or output-to-output is not a wire
        }

        guard var updated = project else { return false }
        guard updated.connect(outModuleId: output.moduleId, outPinId: output.index,
                              toModuleId: input.moduleId, inPinId: input.index) == nil else { return false }

        project = updated
        runtimeDidChangeStructure()
        return true
    }

    /// Removes the wire feeding an input pin. Outputs are not removed directly: an output's wires
    /// belong to the inputs they feed.
    @discardableResult
    public func disconnectPin(_ pin: PinReference) -> Bool {
        guard pin.side == .input, var updated = project else { return false }
        guard updated.disconnect(inModuleId: pin.moduleId, inPinId: pin.index) else { return false }

        project = updated
        runtimeDidChangeStructure()
        return true
    }
}


// MARK: - Canvas transform

/// The mapping between canvas content coordinates and the on-screen viewport.
///
/// The content is drawn as `scaleEffect(zoom, anchor: .topLeading)` followed by `offset(pan)`, so a
/// viewport point is `content * zoom + pan`. A gesture reports viewport coordinates while the pin
/// geometry is in content coordinates, and getting this inversion wrong is invisible until someone
/// drags a wire and nothing happens — which is exactly what occurred, so it lives here where it can
/// be tested rather than being an expression buried in a view.
public enum CanvasTransform {
    public static func viewportPoint(from content: CGPoint, zoom: CGFloat, pan: CGSize) -> CGPoint {
        CGPoint(x: content.x * zoom + pan.width, y: content.y * zoom + pan.height)
    }

    public static func contentPoint(from viewport: CGPoint, zoom: CGFloat, pan: CGSize) -> CGPoint {
        guard zoom != 0 else { return viewport }
        return CGPoint(x: (viewport.x - pan.width) / zoom, y: (viewport.y - pan.height) / zoom)
    }
}
