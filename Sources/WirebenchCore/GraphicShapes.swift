import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The enclosing box of a drawn shape, in sheet coordinates.
///
/// Dirigo writes a shape as the two opposite corners it is drawn between, so this box is both the
/// app's model of the object and its encoding — there is no third representation to keep in step.
public struct GraphicBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// The two corner nodes, in the order a shape is normally written: top-leading first.
    public var corners: [RoutePoint] {
        [RoutePoint(x: x, y: y), RoutePoint(x: maxX, y: maxY)]
    }

    /// Sorts the corners, so a box dragged backwards (negative width or height) still describes the
    /// rectangle it covers.
    public func normalized() -> GraphicBox {
        GraphicBox(x: Swift.min(x, maxX), y: Swift.min(y, maxY),
                   width: Swift.abs(width), height: Swift.abs(height))
    }

    /// The box moved by a delta, its size unchanged.
    public func offsetBy(dx: Double, dy: Double) -> GraphicBox {
        GraphicBox(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// The box with its trailing-bottom corner pulled to a new point. Handles the whole shape being
    /// dragged through its anchor by normalising the result.
    public func resized(maxX newMaxX: Double, maxY newMaxY: Double) -> GraphicBox {
        GraphicBox(x: x, y: y, width: newMaxX - x, height: newMaxY - y).normalized()
    }
}

extension ProjectGraphic {
    /// The object's kind, or `nil` for a type this app has no name for — which is what a future
    /// Dirigo release or a hand-edited file can contain.
    public var objectKind: PCCGraphicBuilder.Kind? {
        PCCGraphicBuilder.Kind(rawValue: type)
    }

    /// True for the outlined objects (rectangle, ellipse), as opposed to text and lines.
    public var isShape: Bool {
        objectKind == .rectangle || objectKind == .ellipse
    }

    /// A shape's box, taken from its two corner nodes.
    ///
    /// `nil` for anything that is not a shape, and for a shape too malformed to enclose a box (fewer
    /// than two nodes) — the caller then draws nothing rather than guessing a geometry.
    public var boundingBox: GraphicBox? {
        guard isShape, nodes.count >= 2 else { return nil }
        let first = nodes[0]
        let second = nodes[1]
        return GraphicBox(x: Swift.min(first.x, second.x),
                          y: Swift.min(first.y, second.y),
                          width: Swift.abs(second.x - first.x),
                          height: Swift.abs(second.y - first.y))
    }

    /// Moves or resizes a shape.
    ///
    /// A graphic read from a file carries its children verbatim, and the serializer prefers those
    /// over the typed fields, so `NODES` has to be rewritten here too. Without that, dragging a
    /// shape loaded from disk would move what the app draws but not what gets saved.
    public mutating func setBoundingBox(_ box: GraphicBox) {
        let corners = box.corners
        nodes = corners
        guard !rawChildren.isEmpty else { return }

        let nodesElement = RawXMLNode(name: "NODES", children: corners.map {
            RawXMLNode(name: "NODE", attributes: AttributeBag([
                ("X", PCCGraphicBuilder.number($0.x)),
                ("Y", PCCGraphicBuilder.number($0.y)),
            ]))
        })
        if let existing = rawChildren.firstIndex(where: { $0.name == "NODES" }) {
            rawChildren[existing] = nodesElement
        } else {
            rawChildren.insert(nodesElement, at: 0)
        }
    }
}
