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

    let initial: String

    /// `@State` is a macro in this SDK, so it has **no `_draft` backing storage to assign from `init`**:
    /// the `_draft = State(initialValue:)` idiom this type used is a compile error, and it is why the app
    /// target did not build. The draft is seeded from `onAppear` instead, and `width` measures `initial`
    /// until it is, so the first render is already the right size and nothing snaps.
    @State private var draft: String = ""
    @State private var isSeeded = false
    @FocusState private var isFocused: Bool

    init(initial: String,
         fontSize: CGFloat,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.fontSize = fontSize
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.initial = initial
    }

    /// A monospaced advance is roughly 0.6 of the point size at this scale, plus the chip's padding.
    private func width(of text: String) -> CGFloat {
        max(44, CGFloat(max(text.count, 1)) * fontSize * 0.62 + 20)
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .frame(width: width(of: isSeeded ? draft : initial))
            .focused($isFocused)
            .onSubmit { onCommit(draft) }
            .onExitCommand { onCancel() }
            .onAppear {
                if !isSeeded {
                    draft = initial
                    isSeeded = true
                }
                isFocused = true
            }
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
