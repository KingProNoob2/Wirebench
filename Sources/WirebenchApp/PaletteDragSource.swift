import SwiftUI
import AppKit

/// A transparent layer over a block-picker row that tells a click from a drag by itself.
///
/// SwiftUI's own `onDrag` never started from these rows: the row sits in a `List`, inside a popover, and the list's selection and a
/// tap gesture both want the mouse-down. This takes the mouse instead and starts a native drag the way any AppKit view does: a click
/// (the mouse goes down and up in place) calls `onClick`, and a drag of more than a few points begins a dragging session that carries
/// `payload`, which the sheet accepts (`AppModel.placePaletteItem`).
struct PaletteDragSource: NSViewRepresentable {
    let payload: String
    let title: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.payload = payload
        view.title = title
        view.onClick = onClick
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var payload = ""
        var title = ""
        var onClick: () -> Void = {}
        private var pressedAt: NSPoint?
        private var isDragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            pressedAt = event.locationInWindow
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let start = pressedAt else { return }
            let here = event.locationInWindow
            guard hypot(here.x - start.x, here.y - start.y) > 4 else { return }
            isDragging = true

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(payload, forType: .string)
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let image = Self.badge(for: title)
            let at = convert(here, from: nil)
            item.setDraggingFrame(NSRect(x: at.x - image.size.width / 2, y: at.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            // A drag that goes nowhere ends where it is, rather than the picture sliding back across the window.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressedAt = nil }
            if !isDragging, pressedAt != nil { onClick() }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

        /// The drag is over and its picture gone. Only now is the block added, so the picture does not wait on the work of adding it.
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            NotificationCenter.default.post(name: .paletteDragEnded, object: nil, userInfo: ["payload": payload])
        }

        /// What follows the pointer: the block's name on a small rounded card.
        private static func badge(for title: String) -> NSImage {
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let size = NSSize(width: max(96, text.size().width + 28), height: 34)
            return NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                text.draw(at: NSPoint(x: (rect.width - text.size().width) / 2, y: (rect.height - text.size().height) / 2))
                return true
            }
        }
    }
}
