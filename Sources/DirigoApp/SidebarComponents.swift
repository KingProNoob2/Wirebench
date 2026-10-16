import SwiftUI

/// The sidebar's small building blocks.
///
/// They live apart from `MainView` for a practical reason: the sidebar sits inside a
/// `NavigationSplitView`, which cannot be rendered offscreen at all — `ImageRenderer` returns the
/// "unsupported view" placeholder. Anything visual kept private to `MainView` can therefore only be
/// checked by eye in the running app. As their own views these can be laid out and looked at.
enum SidebarMetrics {
    static let iconTile: CGFloat = 20
    static let searchCornerRadius: CGFloat = 9
    static let outerPadding: CGFloat = 10

    /// A tinted rounded square behind a row's glyph.
    static func tile<S: View>(tint: Color, fill: Double = 0.15, @ViewBuilder content: () -> S) -> some View {
        content()
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: iconTile, height: iconTile)
            .background(tint.opacity(fill),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Small tracked capitals, so the groups read as groups at a glance.
struct SidebarSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

/// The glass field at the top of the sidebar.
///
/// Deliberately not the system `.searchable`: that drops a stock, blue-ringed control into the
/// sidebar, which does not match the rest of the app's chrome.
struct SidebarSearchField: View {
    @Binding var text: String
    var prompt: String = "Search blocks"

    private var isSearching: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if isSearching {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassPanel(cornerRadius: SidebarMetrics.searchCornerRadius, interactive: true)
        .padding(.horizontal, SidebarMetrics.outerPadding)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// A section's add button: a plain borderless glyph, the way a sidebar action normally looks.
///
/// It was a tinted glass circle for a while, which read as a solid coloured blob in the sidebar
/// rather than a control.
struct SidebarAddButton: View {
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? tint : tint.opacity(0.85))
                .frame(width: 18, height: 18)
                // Its own hover highlight rather than a borderless AppKit button: this is pure
                // SwiftUI, so it draws the same everywhere and stays put next to the title.
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.10) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// A counted pill. Quieter when the count is zero, so empty pages recede.
struct SidebarCountBadge: View {
    let count: Int
    /// On a selected row, whose background is the accent colour: the badge is white on a lighter pill.
    var onAccent = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(onAccent ? Color.white : (count == 0 ? Color.secondary.opacity(0.6) : Color.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(onAccent ? Color.white.opacity(0.24) : Color.primary.opacity(0.08),
                        in: Capsule(style: .continuous))
    }
}

/// One sidebar row: tinted glyph tile, name, count.
struct SidebarRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let count: Int

    /// `.increased` when the list draws this row selected, on the accent colour. The tile and badge are
    /// accent-tinted, so left alone they vanish into that background (a blue glyph on a blue row).
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack(spacing: 8) {
            SidebarMetrics.tile(tint: selected ? .white : tint, fill: selected ? 0.24 : 0.15) {
                Image(systemName: symbol)
            }
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            SidebarCountBadge(count: count, onAccent: selected)
        }
    }
}
