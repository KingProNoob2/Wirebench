import Foundation
import WirebenchCore

/// One end of a wire.
///
/// The original wires **input to output** and nothing else (`GrafickeOkno.html`), so a reference
/// always names a side; the rules themselves live in `PCCProject.connect` where they are testable.
public enum PinSide: Equatable, Sendable {
    case input
    /// A parameter pin: drawn among the inputs, wired like one, and kept in the file's `PARAM_CONNECTIONS`.
    case param
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

    /// Where a pin's bead is drawn — the point a wire attaches to, and the point a snap ring goes round.
    ///
    /// The pin's *anchor* is on the card's edge (`CardGeometry.inPinPoint` and friends); the bead sits
    /// `beadInset` inside it, which is what a user aims at, so both the wire and the ring use this.
    public static func anchor(for reference: PinReference, in project: PCCProject) -> CGPoint? {
        guard let module = project.modules.first(where: { $0.id == reference.moduleId }) else { return nil }
        let inset = CardGeometry.Metrics.beadInset
        switch reference.side {
        case .input:
            let edge = CardGeometry.inPinPoint(for: module, pinIndex: reference.index)
            return CGPoint(x: edge.x + inset, y: edge.y)
        case .param:
            let edge = CardGeometry.paramPinPoint(for: module, pinIndex: reference.index)
            return CGPoint(x: edge.x + inset, y: edge.y)
        case .output:
            let edge = CardGeometry.outPinPoint(for: module, pinIndex: reference.index)
            return CGPoint(x: edge.x - inset, y: edge.y)
        }
    }

    /// The pin a wire being dragged from `origin` would join: the nearest pin of the *opposite* side inside the
    /// band the drag itself uses. Qt's `pinAt(x, y, "in")` is this for a drag that started on an output, and its
    /// preview snaps the cable end onto the same point it would connect to.
    ///
    /// The origin's own module is skipped, because `connectPins` refuses a module wired to itself — a ring there
    /// would promise a connection that would not be made.
    public static func target(at point: CGPoint, from origin: PinReference, in project: PCCProject,
                              pageModuleIds: Set<Int>) -> PinReference? {
        var best: (reference: PinReference, distance: CGFloat)?
        func consider(_ reference: PinReference, _ candidate: CGPoint) {
            let dx = abs(point.x - candidate.x)
            let dy = abs(point.y - candidate.y)
            guard dx <= horizontalReach, dy <= verticalTolerance else { return }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (reference, distance) }
        }
        let wanted: [PinSide] = origin.side == .output ? [.input, .param] : [.output]
        for module in project.modules where pageModuleIds.contains(module.id) && module.id != origin.moduleId {
            for side in wanted {
                let count: Int
                switch side {
                case .input: count = module.inPins.count
                case .param: count = module.paramPins.count
                case .output: count = module.outPins.count
                }
                for index in 0..<count {
                    let reference = PinReference(moduleId: module.id, side: side, index: index)
                    if let anchor = anchor(for: reference, in: project) { consider(reference, anchor) }
                }
            }
        }
        return best?.reference
    }

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
                         CardGeometry.inPinPoint(for: module, pinIndex: index))
            }
            for index in 0..<module.paramPins.count {
                consider(PinReference(moduleId: module.id, side: .param, index: index),
                         CardGeometry.paramPinPoint(for: module, pinIndex: index))
            }
            for index in 0..<module.outPins.count {
                consider(PinReference(moduleId: module.id, side: .output, index: index),
                         CardGeometry.outPinPoint(for: module, pinIndex: index))
            }
        }
        return best?.reference
    }
}

// MARK: - The cable being dragged

/// The shape a wire is drawn with while it is being dragged.
public enum WirePreview {
    /// The elbow Qt draws for the cable in flight: a short run out of the pin, across, then into the pointer (or the
    /// pin it has snapped to). The turn is half way when there is room for it and a fixed stub when there is not —
    /// Qt's rule, `end.x > start.x + 36 ? (start.x + end.x) / 2 : start.x + 18` — mirrored when the drag started on
    /// an input, whose cable leaves to the left.
    ///
    /// Returned as points rather than a `Path` so this layer stays free of SwiftUI.
    public static func elbow(from start: CGPoint, to end: CGPoint, leaving side: PinSide) -> [CGPoint] {
        let turn: CGFloat
        if side == .output {
            turn = end.x > start.x + 36 ? (start.x + end.x) / 2 : start.x + 18
        } else {
            turn = end.x < start.x - 36 ? (start.x + end.x) / 2 : start.x - 18
        }
        return [start, CGPoint(x: turn, y: start.y), CGPoint(x: turn, y: end.y), end]
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
        // A block may feed its own input: a counter's output into its own reset is exactly how a self-resetting counter
        // is built, and the engine reads the producer's value as it stands, which is feedback, not a cycle to reject.
        let output: PinReference
        let input: PinReference
        switch (from.side, to.side) {
        case (.output, .input), (.output, .param): output = from; input = to
        case (.input, .output), (.param, .output): output = to; input = from
        default: return false          // input-to-input or output-to-output is not a wire
        }

        guard var updated = project else { return false }
        guard updated.connect(outModuleId: output.moduleId, outPinId: output.index,
                              toModuleId: input.moduleId, inPinId: input.index, toParam: input.side == .param) == nil
        else { return false }

        project = updated
        runtimeDidChangeStructure()
        return true
    }

    /// Picks a wire, ending the block and graphic selections — or clears the pick when `key` is nil.
    public func selectWire(_ key: RoutedWire.Key?) {
        guard let key else { selectedWire = nil; return }
        selectedModuleId = nil
        selectedModuleIds = []
        selectedAnnotationIndex = nil
        selectedAnnotationIndices = []
        selectedWire = key
    }

    /// Removes the picked wire. The wire belongs to its input pin, so this is `disconnectPin` on that pin — an output's
    /// wires are removed from the inputs they feed, never from the output.
    @discardableResult
    public func deleteSelectedWire() -> Bool {
        guard let wire = selectedWire else { return false }
        selectedWire = nil
        return disconnectPin(PinReference(moduleId: wire.inModule,
                                          side: wire.inParam ? .param : .input, index: wire.inPin))
    }

    /// Removes the wire feeding an input pin. Outputs are not removed directly: an output's wires
    /// belong to the inputs they feed.
    @discardableResult
    public func disconnectPin(_ pin: PinReference) -> Bool {
        guard pin.side == .input || pin.side == .param, var updated = project else { return false }
        guard updated.disconnect(inModuleId: pin.moduleId, inPinId: pin.index, param: pin.side == .param) else { return false }

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
