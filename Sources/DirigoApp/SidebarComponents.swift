import SwiftUI

/// The sidebar's small building blocks.
///
/// They live apart from `MainView` for a practical reason: the sidebar sits inside a
/// `NavigationSplitView`, which cannot be rendered offscreen at all — `ImageRenderer` returns the
/// "unsupported view" placeholder. Anything visual kept private to `MainView` can therefore only be
/// checked by eye in the running app. As their own views these can be laid out and looked at.
enum SidebarMetrics {
    static let searchCornerRadius: CGFloat = 7
    static let outerPadding: CGFloat = 10
}

/// A group title, in the weight and size macOS uses for its own sidebar headers.
struct SidebarSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The search field at the top of the sidebar: a quiet filled field, like Finder's and Mail's.
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
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
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: SidebarMetrics.searchCornerRadius, style: .continuous))
        .padding(.horizontal, SidebarMetrics.outerPadding)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
                .foregroundStyle(isHovering ? Color.primary : tint)
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
        .accessibilityLabel(help)
    }
}

/// A row's block count, as plain trailing digits the way Mail shows unread counts. Empty pages
/// show nothing, so the eye goes to the pages that have something on them.
struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) block\(count == 1 ? "" : "s")")
        }
    }
}

/// One sidebar row: glyph, name, count.
struct SidebarRow: View {
    let symbol: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            // A plain `Label` so the list styles the glyph itself, including on a selected row.
            // Truncated in the middle, so two long page names that differ only at the end stay distinct.
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            SidebarCountBadge(count: count)
        }
    }
}
