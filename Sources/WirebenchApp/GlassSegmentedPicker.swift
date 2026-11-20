import SwiftUI

/// A segmented picker drawn as one liquid-glass capsule instead of AppKit's blue segmented control.
///
/// The selection is a second glass capsule inside the container; on macOS 26 both use the system
/// glass effect through `glassPanel`, and on earlier systems they use the app's material fallback.
struct GlassSegmentedPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    var accessibilityLabel: String = ""

    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(.snappy(duration: 0.18, extraBounce: 0.05)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.clear)
                                    .glassCapsule(tint: .accentColor, tintOpacity: 0.20)
                                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .glassCapsule(interactive: true, tintOpacity: 0.06)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
