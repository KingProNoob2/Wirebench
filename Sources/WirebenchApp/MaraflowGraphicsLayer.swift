import SwiftUI
import WirebenchCore
import WirebenchModel

/// Draws an imported Maraflow page's graphic objects the way Maraflow's `FbdCanvas.paintGraphicElements` does:
/// signed grid boxes, its shape vocabulary, dashed strokes, visual buttons and live indicator fills. This is separate
/// from Dirigo's `ProjectGraphic` model, which has only rectangle/ellipse/line/text and no bindings.
struct MaraflowGraphicsLayer: View {
    @Bindable var model: AppModel
    /// Changes whenever the simulation values do. Passing it as a value makes the canvas redraw even though the
    /// indicator lookups happen inside the `Canvas` closure.
    let version: UInt64

    private let grid: CGFloat = 32

    private var pageIndex: Int {
        model.project?.pages.firstIndex { $0.caption == model.selectedPage } ?? 0
    }

    private var graphics: [MaraflowExtras.Graphic] {
        model.project?.maraflow?.graphics(onPageIndex: pageIndex) ?? []
    }

    var body: some View {
        let graphics = graphics
        if !graphics.isEmpty {
            // The timeline is the backstop that keeps indicators moving while the simulation plays even if no other
            // observed value happens to change in a frame; snapshots and `version` still drive paused edits.
            TimelineView(.animation(minimumInterval: 0.1, paused: !model.isPlaying)) { _ in
                let _ = version
                let current = self.graphics
                let isActive = current.map { graphic in
                    graphic.indicatorEnabled && !graphic.indicatorPin.isEmpty
                        && model.maraflowBooleanValue(graphic.indicatorPin)
                }
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for (index, graphic) in current.enumerated() where graphic.kind != "VISUAL_BUTTON" {
                            draw(graphic, active: isActive[index], in: &context)
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(Array(current.enumerated()), id: \.offset) { _, graphic in
                        if graphic.kind == "VISUAL_BUTTON" {
                            MaraflowVisualButton(model: model, graphic: graphic, grid: grid)
                        }
                    }
                }
            }
        }
    }

    private func draw(_ graphic: MaraflowExtras.Graphic, active: Bool, in context: inout GraphicsContext) {
        let rect = self.rect(for: graphic)
        let kind = graphic.kind.uppercased()
        if kind == "TEXT" {
            let text = Text(graphic.text.isEmpty ? "Text" : graphic.text)
                .font(.system(size: max(8, CGFloat(graphic.fontSize) * 1.6)))
                .foregroundStyle(color(graphic.strokeRgb))
            context.draw(text, at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
            return
        }
        if kind == "LINE" {
            var path = Path()
            path.move(to: CGPoint(x: CGFloat(graphic.gridX) * grid, y: CGFloat(graphic.gridY) * grid))
            path.addLine(to: CGPoint(x: CGFloat(graphic.gridX + graphic.gridW) * grid,
                                     y: CGFloat(graphic.gridY + graphic.gridH) * grid))
            context.stroke(path, with: .color(color(graphic.strokeRgb)), style: strokeStyle(graphic))
            return
        }

        let indicatorConfigured = graphic.indicatorEnabled && !graphic.indicatorPin.isEmpty
        let shouldFill = graphic.filled || indicatorConfigured
        let fill = color(indicatorConfigured
                         ? (active ? graphic.indicatorActiveColor : graphic.indicatorInactiveColor)
                         : graphic.fillRgb)

        if kind == "CIRCLE" {
            let side = min(rect.width, rect.height)
            let circleRect = CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
            if shouldFill { context.fill(Path(ellipseIn: circleRect), with: .color(fill)) }
            context.stroke(Path(ellipseIn: circleRect), with: .color(color(graphic.strokeRgb)), style: strokeStyle(graphic))
            return
        }

        guard let path = path(for: graphic, rect: rect) else { return }
        if shouldFill {
            var fillPath = path
            if kind == "ARC" || kind == "SECTOR" {
                fillPath.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
                fillPath.closeSubpath()
            }
            context.fill(fillPath, with: .color(fill))
        }
        context.stroke(path, with: .color(color(graphic.strokeRgb)), style: strokeStyle(graphic))
    }

    private func rect(for graphic: MaraflowExtras.Graphic) -> CGRect {
        if graphic.kind.uppercased() == "TEXT" {
            return CGRect(x: CGFloat(graphic.gridX) * grid, y: CGFloat(graphic.gridY) * grid,
                          width: grid, height: grid)
        }
        let x1 = CGFloat(graphic.gridX) * grid
        let y1 = CGFloat(graphic.gridY) * grid
        let x2 = CGFloat(graphic.gridX + graphic.gridW) * grid
        let y2 = CGFloat(graphic.gridY + graphic.gridH) * grid
        return CGRect(x: min(x1, x2), y: min(y1, y2),
                      width: max(grid, abs(x2 - x1)), height: max(grid, abs(y2 - y1)))
    }

    private func path(for graphic: MaraflowExtras.Graphic, rect: CGRect) -> Path? {
        switch graphic.kind.uppercased() {
        case "RECTANGLE":
            return Path(rect)
        case "ROUNDED_RECTANGLE":
            return Path(roundedRect: rect, cornerRadius: max(4, grid))
        case "ELLIPSE":
            return Path(ellipseIn: rect)
        case "TRIANGLE":
            return polygon(rect: rect, sides: 3)
        case "PENTAGON":
            return polygon(rect: rect, sides: 5)
        case "HEXAGON":
            return polygon(rect: rect, sides: 6)
        case "OCTAGON":
            return polygon(rect: rect, sides: 8)
        case "CUSTOM_NGON":
            return polygon(rect: rect, sides: max(3, graphic.ngonSides))
        case "ARC", "SECTOR":
            return arc(rect: rect, filledSector: graphic.kind.uppercased() == "SECTOR")
        default:
            return Path(rect)
        }
    }

    private func polygon(rect: CGRect, sides: Int) -> Path {
        var path = Path()
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        for side in 0..<sides {
            let angle = -CGFloat.pi / 2 + CGFloat(side) * 2 * .pi / CGFloat(sides)
            let point = CGPoint(x: rect.midX + cos(angle) * radiusX,
                                y: rect.midY + sin(angle) * radiusY)
            if side == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Maraflow draws an arc from 20° for 220°, and a sector from 30° for 240°.
    private func arc(rect: CGRect, filledSector: Bool) -> Path {
        let start = filledSector ? 30.0 : 20.0
        let sweep = filledSector ? 240.0 : 220.0
        var path = Path()
        let steps = 48
        for step in 0...steps {
            let degrees = start + sweep * Double(step) / Double(steps)
            let angle = CGFloat(degrees * .pi / 180)
            let point = CGPoint(x: rect.midX + cos(angle) * rect.width / 2,
                                y: rect.midY + sin(angle) * rect.height / 2)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if filledSector {
            path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
            path.closeSubpath()
        }
        return path
    }

    private func color(_ rgb: Int) -> Color {
        let value = UInt32(bitPattern: Int32(rgb))
        let alpha = Double((value >> 24) & 0xFF) / 255
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255,
                     opacity: alpha == 0 ? 1 : alpha)
    }

    private func strokeStyle(_ graphic: MaraflowExtras.Graphic) -> StrokeStyle {
        StrokeStyle(lineWidth: max(1, CGFloat(graphic.strokeWidth)),
                    dash: graphic.dashed ? [5, 4] : [])
    }
}

/// A Maraflow visual button: a small labelled rectangle that writes its bound pin.
private struct MaraflowVisualButton: View {
    @Bindable var model: AppModel
    let graphic: MaraflowExtras.Graphic
    let grid: CGFloat

    private var rect: CGRect {
        let x1 = CGFloat(graphic.gridX) * grid
        let y1 = CGFloat(graphic.gridY) * grid
        let x2 = CGFloat(graphic.gridX + graphic.gridW) * grid
        let y2 = CGFloat(graphic.gridY + graphic.gridH) * grid
        return CGRect(x: min(x1, x2), y: min(y1, y2),
                      width: max(grid, abs(x2 - x1)), height: max(grid, abs(y2 - y1)))
    }

    private var pressed: Bool {
        guard !graphic.boundTargetPin.isEmpty,
              let binding = model.maraflowBinding(graphic.boundTargetPin, output: false),
              let node = model.getNode(id: binding.moduleId),
              binding.pinIndex < node.block.inPins.count else { return false }
        return node.block.inPins[binding.pinIndex].asBool
    }

    var body: some View {
        Button {
            model.pressMaraflowBinding(graphic.boundTargetPin)
        } label: {
            Text(graphic.text.isEmpty ? "Button" : graphic.text)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(pressed ? Color(red: 0x76/255, green: 0xD7/255, blue: 0xC4/255)
                                    : Color(red: 0xE2/255, green: 0xE6/255, blue: 0xEA/255))
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .help(graphic.boundTargetPin.isEmpty ? graphic.text : "\(graphic.text) → \(graphic.boundTargetPin)")
    }
}
