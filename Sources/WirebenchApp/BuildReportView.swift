import WirebenchModel
import SwiftUI

/// What a build produced, and what it left out.
///
/// Takes the report and the actions rather than the whole model: the sheet's inputs are one value and
/// four closures, so it invalidates when a build replaces the report and not when anything else about the
/// project changes.
struct BuildReportSheet: View {
    let report: AppModel.BuildReport
    /// What the last export did. An alert cannot show over this sheet, so it is told here.
    let notice: AppModel.PendingAlert?
    let onExportProgram: () -> Void
    let onExportSymbols: () -> Void
    let onExportVariables: () -> Void
    let optimize: Binding<Bool>
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

            // Each number on a tile. The popup itself is the glass, so these are flat: glass stacked on glass goes muddy.
            HStack(spacing: 10) {
                ForEach(stats, id: \.label) { stat in
                    BuildStatTile(label: stat.label, value: stat.value)
                }
            }

            ScrollView {
                Text(report.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 90, maxHeight: 190)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let notice {
                BuildNoticeRow(notice: notice)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Toggle("Optimize program", isOn: optimize)
                .help("Order the records so values settle in fewer cycles, and drop logic and math that nothing reads or that is switched off. Addresses do not change.")

            Divider()

            GlassGroup(spacing: 8) {
                HStack {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .glassButtonStyle()
                    Spacer()
                    Button("Export CSV\u{2026}", action: onExportSymbols)
                        .glassButtonStyle()
                        .help("Export the symbol table as a CSV file")
                    Button("Export Variables\u{2026}", action: onExportVariables)
                        .glassButtonStyle()
                        .help("Export the program variables as a dBase file (.dbf), the one Dirigo writes beside a project")
                    Button("Export Program\u{2026}", action: onExportProgram)
                        .glassButtonStyle()
                        .help("Export the program binary (.pbd)")
                    // The highlighted button: compiling is done, so uploading is the next step.
                    Button("Upload to PLC\u{2026}", action: onUpload)
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 340)
    }
}

/// What an export just did, on the report itself.
private struct BuildNoticeRow: View {
    let notice: AppModel.PendingAlert

    var body: some View {
        let succeeded = notice.kind == .info
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).bold()
                Text(notice.message).foregroundStyle(.secondary)
            }
            .font(.callout)
            .textSelection(.enabled)
        } icon: {
            Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(succeeded ? Color.green : Color.orange)
        }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The Duino-S build report: what the FBD project compiled to, and the one action that matters next.
struct DuinoBuildReportSheet: View {
    let result: DuinoCompiler.Result
    let onUpload: () -> Void
    let onClose: () -> Void

    private var usedSlots: Int { Set(result.slots.values).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duino-S Build")
                .font(.title2)
                .bold()
            Text("MFLW v1 bytecode for the Maramat Duino-S (model 0x0407).")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                BuildStatTile(label: "Image", value: "\(result.image.count) B")
                BuildStatTile(label: "Slots", value: "\(usedSlots)")
                BuildStatTile(label: "Threads", value: "5")
                BuildStatTile(label: "Model", value: "0x0407")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The image is ready to upload over the selected USB CDC port.")
                        .font(.callout)
                    ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(minHeight: 90, maxHeight: 190)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Divider()

            GlassGroup(spacing: 8) {
                HStack {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .glassButtonStyle()
                    Spacer()
                    Button("Upload to Duino-S…", action: onUpload)
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 320)
    }
}
