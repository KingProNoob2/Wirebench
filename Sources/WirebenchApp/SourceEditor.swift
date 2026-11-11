import SwiftUI
import AppKit
import WirebenchSource

/// The source editor: a plain `NSTextView` with a line-number gutter and colours from the compiler's own parse.
///
/// SwiftUI's `TextEditor` has no line numbers and no way to colour ranges, and the IDE needs both. The text view is the
/// document; the colours are applied to its storage, and changing them does not touch the text or the undo stack.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var spans: [SyntaxSpan]
    var selectedLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        textView.delegate = context.coordinator
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.apply(spans: spans)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if spans != context.coordinator.applied {
            context.coordinator.apply(spans: spans)
        }
        context.coordinator.ruler?.needsDisplay = true
        if let line = selectedLine, line != context.coordinator.selectedLine {
            context.coordinator.selectedLine = line
            context.coordinator.select(line: line)
        }
        if selectedLine == nil { context.coordinator.selectedLine = nil }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        var applied: [SyntaxSpan] = []
        var selectedLine: Int?
        private var isApplying = false

        init(_ parent: SourceEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
        }

        func apply(spans: [SyntaxSpan]) {
            guard let storage = textView?.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            isApplying = true
            storage.beginEditing()
            storage.addAttributes([.font: SourceEditor.font, .foregroundColor: NSColor.labelColor], range: full)
            for span in spans {
                let range = NSRange(location: span.location, length: span.length)
                guard range.location >= 0, NSMaxRange(range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: Palette.colour(for: span.kind), range: range)
            }
            storage.endEditing()
            isApplying = false
            applied = spans
        }

        /// Puts the caret on `line` and scrolls it into view.
        func select(line: Int) {
            guard let textView else { return }
            let string = textView.string as NSString
            var index = 0
            var number = 1
            while index < string.length && number < line {
                index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
                number += 1
            }
            let range = string.lineRange(for: NSRange(location: min(index, string.length), length: 0))
            textView.setSelectedRange(NSRange(location: range.location, length: range.length))
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
    }
}

/// The editor's colours. System colours, so they adapt to a light or dark appearance with the rest of the app.
enum Palette {
    static func colour(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .comment: return .secondaryLabelColor
        case .string: return .systemRed
        case .number: return .systemBlue
        case .attribute: return .systemPurple
        case .declaration: return .systemTeal
        case .type: return .systemIndigo
        case .call: return .systemGreen
        case .operatorToken: return .secondaryLabelColor
        }
    }
}

/// The gutter: a line number for each line that starts a line, aligned with the text.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY))
        edge.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY))
        edge.stroke()

        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let visible = scrollView?.contentView.bounds ?? bounds
        let inset = textView.textContainerInset.height
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]

        var index = 0
        var number = 1
        while index <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: min(index, max(0, string.length - 1)))
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = fragment.minY + inset
            if y >= visible.minY - 20 && y <= visible.maxY + 20 {
                let text = "\(number)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: convert(NSPoint(x: 0, y: y), from: textView).y),
                          withAttributes: attributes)
            }
            if y > visible.maxY + 40 { break }
            guard lineRange.length > 0, NSMaxRange(lineRange) > index || string.length == 0 else { break }
            index = max(NSMaxRange(lineRange), index + 1)
            number += 1
            if index >= string.length { break }
        }
        _ = container
    }
}
