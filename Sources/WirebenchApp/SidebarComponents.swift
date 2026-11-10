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

/// The search field at the top of the sidebar, surfaced in the app's glass language like the rest
/// of the chrome.
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
        .glassPanel(RoundedRectangle(cornerRadius: SidebarMetrics.searchCornerRadius,
                                     style: .continuous))
        .padding(.horizontal, SidebarMetrics.outerPadding)
        .padding(.top, 6)
        .padding(.bottom, 4)
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

/// A page's row: a button, with the selection drawn as a tinted glass pill. The pill is one shape shared by the rows (`glassEffectID`), so
/// choosing another page makes it flow from the old row to the new one on macOS 26; before that it is a tinted material that just moves.
///
/// The glass is applied to the row itself, not drawn behind it: a glass shape in a background is composited over the label.
struct SidebarPageRow: View {
    let symbol: String
    let title: String
    let count: Int
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false
    private let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

    var body: some View {
        let row = Button(action: action) {
            SidebarRow(symbol: symbol, title: title, count: count)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            if #available(macOS 26.0, *) {
                row
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.38)), in: shape)
                    .glassEffectID("page-selection", in: selection)
            } else {
                row.background {
                    shape.fill(Color.accentColor.opacity(0.30))
                        .overlay(shape.strokeBorder(Theme.panelStroke, lineWidth: 1))
                }
            }
        } else {
            row.background { if isHovering { shape.fill(Color.primary.opacity(0.07)) } }
        }
    }
}

/// A group's heading: a small glass chip carrying the title, with the group's add button, when it has one, as a glass circle beside it.
struct SidebarSectionHeader: View {
    let title: String
    var addHelp: String?
    var onAdd: (() -> Void)?
    var addDisabled = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassCapsule()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let onAdd, let addHelp {
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(addDisabled)
                .help(addHelp)
                .accessibilityLabel(addHelp)
            }
        }
    }
}

/// A group with nothing in it yet, as one glass card: the group's title with its add button, and under it what is missing. Once the group has rows it
/// is a `SidebarSectionHeader` and the rows instead.
struct SidebarEmptyGroupCard: View {
    let title: String
    let emptyText: String
    let addHelp: String
    let onAdd: () -> Void
    var addDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(addDisabled)
                .help(addHelp)
                .accessibilityLabel(addHelp)
            }
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16)
    }
}
