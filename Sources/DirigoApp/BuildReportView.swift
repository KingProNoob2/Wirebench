import SwiftUI

/// What a build produced, and what it left out.
///
/// Takes the report and the actions rather than the whole model: the sheet's inputs are one value and
/// four closures, so it invalidates when a build replaces the report and not when anything else about the
/// project changes.
struct BuildReportSheet: View {
    let report: AppModel.BuildReport
    let onExportProgram: () -> Void
    let onExportSymbols: () -> Void
    let onUpload: () -> Void
    let onClose: () -> Void

    private var stats: [(label: String, value: String)] {
        [
            ("Modules", "\(report.compiledModules)/\(report.moduleCount)"),
            ("Records", "\(report.recordBytes) B"),
            ("Data slots", "\(report.dataSlots)"),
            ("Terminals", "\(report.terminals)"),
            ("Symbol rows", "\(report.symbolRows)"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build Report")
                .font(.title2)
                .bold()

            HStack(spacing: 22) {
                ForEach(stats, id: \.label) { stat in
                    BuildStatTile(label: stat.label, value: stat.value)
                }
            }

            ScrollView {
                Text(report.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90)

            Divider()

            HStack {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Upload to PLC\u{2026}", action: onUpload)
                Button("Export Symbol Table (CSV)\u{2026}", action: onExportSymbols)
                Button("Export Program Binary\u{2026}", action: onExportProgram)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 340)
    }
}

/// One number from the build report.
private struct BuildStatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
