import Foundation

/// Snapping of module positions to the drafting grid's base pitch (`CanvasGrid`'s base step, in canvas units).
public enum GridSnap {
    public static let step: Double = 32

    public static func snap(_ value: Double, step: Double = GridSnap.step) -> Double {
        (value / step).rounded() * step
    }
}
