import SwiftUI
import AppKit
import WirebenchSource

/// The source editor: a plain `NSTextView` with a line-number gutter and colours from the compiler's own parse.
///
/// SwiftUI's `TextEditor` has no line numbers and no way to colour ranges, and the IDE needs both. The text view is the
/// document; the colours are applied to its storage, and changing them does not touch the text or the undo stack.
@MainActor
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var spans: [SyntaxSpan]
    var selectedLine: Int?
    /// Lines a diagnostic points at; they get a red mark in the text, not only a row in the report.
    var errorLines: [Int] = []

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
        if errorLines != context.coordinator.appliedErrors {
            context.coordinator.applyErrors(lines: errorLines)
        }
        context.coordinator.ruler?.needsDisplay = true
        if let line = selectedLine, line != context.coordinator.selectedLine {
            context.coordinator.selectedLine = line
            context.coordinator.select(line: line)
        }
        if selectedLine == nil { context.coordinator.selectedLine = nil }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Own completion popup, replacing `complete(nil)`: AppKit's built-in window hard-codes
        /// Return to accept, and the editor wants Return to always insert a newline (Tab accepts).
        private var panel: CompletionPanel?
        private var keyMonitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var suppressNextOpen = false

        var parent: SourceEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        var applied: [SyntaxSpan] = []
        var appliedErrors: [Int] = []
        var selectedLine: Int?
        private var isApplying = false

        init(_ parent: SourceEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
            if let panel, panel.isVisible {
                refresh(panel: panel, in: textView)
            } else if !suppressNextOpen {
                scheduleCompletion(in: textView)
            }
            suppressNextOpen = false
        }

        private var completionWork: DispatchWorkItem?

        /// Opens the completion window while the user types an identifier or a member access.
        /// Debounced: firing on every keystroke makes the window flicker.
        private func scheduleCompletion(in textView: NSTextView) {
            completionWork?.cancel()
            let caret = textView.selectedRange().location
            guard caret > 0 else { return }
            let typed = (textView.string as NSString).character(at: caret - 1)
            let triggers = CharacterSet.letters.union(.decimalDigits)
                .union(CharacterSet(charactersIn: "._ ")).contains
            guard let scalar = Unicode.Scalar(typed), triggers(scalar) else { return }
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.openCompletion(in: textView)
            }
            completionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// The word (letters, digits, underscore) around the caret, as a UTF-16 range.
        /// The completion state at the caret: the range a suggestion would replace, and the
        /// suggestions for the context around it. The partial word is empty when the caret sits
        /// after a space — the context then decides what is offered.
        private struct CompletionState {
            var range: NSRange
            var partial: String
            var suggestions: [SourceCompletion.Suggestion]
        }

        private func completionState(in textView: NSTextView) -> CompletionState? {
            let caret = textView.selectedRange().location
            let string = textView.string as NSString
            guard caret > 0, caret <= string.length else { return nil }
            let wordLetters = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_"))
            func isWord(_ index: Int) -> Bool {
                guard index >= 0, index < string.length,
                      let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
                return wordLetters.contains(scalar)
            }
            func isSpace(_ index: Int) -> Bool {
                guard index >= 0, index < string.length else { return false }
                return string.character(at: index) == 0x20
            }
            let range: NSRange
            if isWord(caret - 1) {
                var start = caret - 1
                while start > 0, isWord(start - 1) { start -= 1 }
                var end = caret
                while end < string.length, isWord(end) { end += 1 }
                range = NSRange(location: start, length: end - start)
            } else {
                // After whitespace: offer context. Only on a space — a newline or operator ends
                // the thought. Not where a unit name follows PROGRAM or FUNCTION_BLOCK.
                guard isSpace(caret - 1) else { return nil }
                var tokenEnd = caret - 1
                while tokenEnd > 0, isSpace(tokenEnd - 1) { tokenEnd -= 1 }
                var tokenStart = tokenEnd
                while tokenStart > 0, isWord(tokenStart - 1) { tokenStart -= 1 }
                let token = string.substring(with: NSRange(location: tokenStart, length: tokenEnd - tokenStart))
                let upper = token.uppercased()
                guard upper != "PROGRAM", upper != "FUNCTION_BLOCK" else { return nil }
                range = NSRange(location: caret, length: 0)
            }
            let partial = string.substring(with: range)
            let before = string.substring(to: range.location)
            let suggestions = SourceCompletion.suggestionsWithKinds(in: textView.string, partial: partial,
                                                                    beforeCaret: before)
            guard !suggestions.isEmpty else { return nil }
            return CompletionState(range: range, partial: partial, suggestions: suggestions)
        }

        private func openCompletion(in textView: NSTextView) {
            guard let state = completionState(in: textView),
                  let window = textView.window else { return }
            let caret = textView.firstRect(forCharacterRange: NSRange(location: state.range.location, length: 0),
                                           actualRange: nil)
            let panel = self.panel ?? CompletionPanel()
            self.panel = panel
            panel.onAccept = { [weak self, weak textView] suggestion in
                guard let self, let textView else { return }
                self.accept(suggestion.insert ?? suggestion.text, range: state.range, in: textView)
            }
            panel.show(suggestions: state.suggestions, partial: state.partial, near: caret, in: window)
            installKeyMonitor()
            if resignObserver == nil {
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.closeCompletion()
                    }
                }
            }
        }

        /// Re-filter and re-anchor the open panel after the text changed; close it when the caret
        /// left the word or nothing matches any more.
        private func refresh(panel: CompletionPanel, in textView: NSTextView) {
            guard let state = completionState(in: textView) else {
                closeCompletion()
                return
            }
            guard let window = textView.window else {
                closeCompletion()
                return
            }
            let caret = textView.firstRect(forCharacterRange: NSRange(location: state.range.location, length: 0),
                                           actualRange: nil)
            panel.show(suggestions: state.suggestions, partial: state.partial, near: caret, in: window)
        }

        private func accept(_ suggestion: String, range: NSRange, in textView: NSTextView) {
            suppressNextOpen = true
            textView.insertText(suggestion, replacementRange: range)
            textView.window?.makeFirstResponder(textView)
            closeCompletion()
        }

        private func closeCompletion() {
            panel?.orderOut(nil)
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let observer = resignObserver {
                NotificationCenter.default.removeObserver(observer)
                resignObserver = nil
            }
        }

        /// Keys the panel owns while it is up: Tab accepts, arrows move, Escape closes. Return and
        /// Enter are deliberately passed through: they insert a newline, as they do everywhere else.
        private func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let panel = self.panel, panel.isVisible, let textView = self.textView else { return event }
                switch event.keyCode {
                case 48: // Tab
                    if let state = self.completionState(in: textView), let item = panel.selectedItem() {
                        self.accept(item.insert ?? item.text, range: state.range, in: textView)
                    } else {
                        self.closeCompletion()
                    }
                    return nil
                case 53: // Escape
                    self.closeCompletion()
                    return nil
                case 125, 126: // Down / Up
                    panel.moveSelection(by: event.keyCode == 125 ? 1 : -1)
                    return nil
                case 36, 76: // Return / Enter: newline, and the word ended — close.
                    self.closeCompletion()
                    return event
                default:
                    return event
                }
            }
        }


        /// Marks each error line: a pale red band and a red underline, so the report and the text agree.
        func applyErrors(lines: [Int]) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let string = textView.string as NSString
            for line in Set(appliedErrors) {
                guard line > 0 else { continue }
                var index = 0, number = 1
                while number < line && index < string.length {
                    index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
                    number += 1
                }
                guard index < string.length || (string.length == 0 && line == 1) else { continue }
                let range = string.lineRange(for: NSRange(location: min(index, string.length), length: 0))
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            }
            appliedErrors = lines
            for line in Set(lines) where line > 0 {
                var index = 0, number = 1
                while number < line && index < string.length {
                    index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
                    number += 1
                }
                guard index < string.length || (string.length == 0 && line == 1) else { continue }
                let range = string.lineRange(for: NSRange(location: min(index, string.length), length: 0))
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: NSColor.systemRed.withAlphaComponent(0.10),
                    .underlineColor: NSColor.systemRed.withAlphaComponent(0.7),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], forCharacterRange: range)
            }
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
@MainActor
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

        // Start at the first visible line: counting from line 1 lays out every line above the viewport on every
        // keystroke, which is quadratic on a large file.
        let probe = NSPoint(x: 0, y: max(0, visible.minY - inset))
        let visibleCharacter = layoutManager.characterIndex(for: probe, in: container,
                                                           fractionOfDistanceBetweenInsertionPoints: nil)
        var index = string.lineRange(for: NSRange(location: min(visibleCharacter, string.length), length: 0)).location
        var number = 1
        var counted = 0
        while counted < index {
            let line = string.lineRange(for: NSRange(location: counted, length: 0))
            counted = max(NSMaxRange(line), counted + 1)
            number += 1
        }
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

/// The completion popup: a small non-activating panel with a list, anchored under the caret.
///
/// It never takes key status — keystrokes keep going to the text view, so Return and Enter insert
/// a newline exactly as they do without the panel; the coordinator's local monitor handles the
/// keys the panel owns (Tab accepts, arrows move, Escape closes).
@MainActor
final class CompletionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let effect = NSVisualEffectView()
    var suggestions: [SourceCompletion.Suggestion] = []
    /// The text the suggestions are filtered by, highlighted at the start of each row.
    var partial: String = ""
    var onAccept: ((SourceCompletion.Suggestion) -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        styleMask = [.borderless, .nonactivatingPanel]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        contentView = effect

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .sourceList
        table.focusRingType = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(acceptSelected)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -5),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
        ])
    }

    /// Shows (or refreshes) the list under the caret, clamped to the screen.
    func show(suggestions: [SourceCompletion.Suggestion], partial: String, near caret: NSRect, in window: NSWindow) {
        self.suggestions = suggestions
        self.partial = partial
        let height = min(220, max(24, CGFloat(suggestions.count) * table.rowHeight) + 12)
        let width: CGFloat = 280
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // `caret` is in screen coordinates with a flipped y; a panel's origin is bottom-left.
        let x = min(max(caret.minX - 28, screen.minX), max(screen.minX, screen.maxX - width))
        let top = caret.minY - 5
        let y = max(screen.minY, top - height)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func selectedItem() -> SourceCompletion.Suggestion? {
        let row = table.selectedRow
        return suggestions.indices.contains(row) ? suggestions[row] : suggestions.first
    }

    func moveSelection(by delta: Int) {
        let row = min(max(table.selectedRow + delta, 0), max(suggestions.count - 1, 0))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func acceptSelected() {
        if let item = selectedItem() { onAccept?(item) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let suggestion = suggestions[row]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 268, height: 22))

        let imageView = NSImageView(frame: NSRect(x: 4, y: 4, width: 14, height: 14))
        let symbol = switch suggestion.kind {
        case .keyword: "textformat"
        case .type: "shippingbox"
        case .name: "curlybraces"
        }
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        container.addSubview(imageView)

        let field = NSTextField(labelWithAttributedString: highlighted(suggestion.text))
        field.frame = NSRect(x: 24, y: 2, width: 236, height: 18)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        container.addSubview(field)
        return container
    }

    /// The row text with the typed prefix standing out, so the eye goes to why each row matched.
    private func highlighted(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
        ])
        if !partial.isEmpty, text.lowercased().hasPrefix(partial.lowercased()) {
            result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: partial.count))
            result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                                range: NSRange(location: 0, length: partial.count))
        }
        return result
    }

    /// A single click selects; the accept gesture is Tab or a double click, so an accidental click
    /// never rewrites the source.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}
