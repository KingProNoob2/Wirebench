import SwiftUI

/// The in-place editor for a text object on the sheet.
///
/// It exists for two reasons the plain `TextField` could not handle:
///
/// * it keeps its own **draft**, so abandoning the edit — Escape, or clicking away — really abandons
///   it rather than leaving half-typed characters in the document;
/// * it **sizes itself to what has been typed**. A `TextField` fills whatever width it is handed, so
///   inside the canvas it stretched across the whole sheet.
struct TextAnnotationEditor: View {
    let fontSize: CGFloat
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(initial: String,
         fontSize: CGFloat,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.fontSize = fontSize
        self.onCommit = onCommit
        self.onCancel = onCancel
        // Seeded here rather than in `onAppear`, so the field is already the right width on its
        // first render instead of snapping to size once it appears.
        _draft = State(initialValue: initial)
    }

    /// A monospaced advance is roughly 0.6 of the point size at this scale, plus the chip's padding.
    private var width: CGFloat {
        max(44, CGFloat(max(draft.count, 1)) * fontSize * 0.62 + 20)
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .frame(width: width)
            .focused($isFocused)
            .onSubmit { onCommit(draft) }
            .onExitCommand { onCancel() }
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                // Clicking anywhere else ends the edit. Committing has already stored the text by
                // then, so this only ever discards nothing.
                if !focused { onCancel() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }
}
