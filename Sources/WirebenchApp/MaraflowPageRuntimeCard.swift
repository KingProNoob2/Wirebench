import SwiftUI

/// A Maraflow Structured Text or ladder page has one hidden runtime module and no ordinary blocks. The sheet used to
/// draw that module as a card (`ST Main_ST #-1 …`), which read like a broken block. This explains the page instead.
struct MaraflowPageRuntimeCard: View {
    let kind: String
    let detail: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kind, systemImage: kind.hasPrefix("Structured") ? "text.alignleft" : "list.bullet.rectangle")
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(code.split(separator: "\n", omittingEmptySubsequences: false).prefix(10).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .help("This page runs its \(kind.lowercased()) in the simulation; it is not a block on the sheet.")
    }
}
