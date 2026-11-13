import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WirebenchCore
import WirebenchModel
import WirebenchSource

/// The Structured Text editor: source on the left, what the compiler says about it on the right.
///
/// It compiles as you type (debounced) so a diagnostic appears where the mistake is made, and the explicit Compile
/// button opens the result in the block editor or saves it as a `.pcc`.
struct SwiftIDEView: View {
    @Bindable var model: AppModel

    @State private var spans: [SyntaxSpan] = []
    /// True when the editor has no text: either a fresh scratch, or a document that carries no source.
    @State private var isEmpty = false
    @State private var compiled: CompiledSource?
    @State private var diagnostics: [SourceError] = []
    @State private var failure: String?
    @State private var jumpLine: Int?
    /// The declarations the report lists, each with the line to jump to; rebuilt with the compile.
    @State private var outlineRows: [(label: String, line: Int)] = []
    @State private var savingError: String?
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        HSplitView {
            editorPane
            reportPane
        }
        .frame(minWidth: 820, minHeight: 440)
        .onAppear {
            // A `.pcc` carries no source, so the editor recovers one from the open project when it has none: the pages,
            // pins and logic the subset can express, and a list of what it cannot.
            if model.swiftSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recoverFromProject() }
            isEmpty = model.swiftSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty { rebuildEmpty() } else { rebuild() }
        }
        .onChange(of: model.currentFileURL) { _, _ in
            // Opening another document leaves an empty buffer; recover that document rather than keep the last one.
            if model.swiftSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recoverFromProject() }
        }
        .onChange(of: model.swiftSource) { _, new in
            isEmpty = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scheduleRebuild()
        }
        .toolbar { toolbar }
        .alert("Could not save the project", isPresented: Binding(
            get: { savingError != nil },
            set: { if !$0 { savingError = nil } }
        )) {
            Button("OK", role: .cancel) { savingError = nil }
        } message: {
            Text(savingError ?? "")
        }
    }

    // MARK: - Editor

    private var editorPane: some View {
        VStack(spacing: 0) {
            SourceEditor(text: $model.swiftSource, spans: spans, selectedLine: jumpLine,
                         errorLines: diagnostics.map(\.line))
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(compiled == nil ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
        }
        .frame(minWidth: 460, maxHeight: .infinity)
    }

    private var lineCount: Int {
        model.swiftSource.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var statusText: String {
        if isEmpty { return model.project == nil ? "No source yet" : "No source for this document" }
        if let compiled {
            let inputs = compiled.usedInputs.map { "DI\($0)" }.joined(separator: " ")
            let outputs = compiled.writtenOutputs.map { "DO\($0)" }.joined(separator: " ")
            let parts = [inputs, outputs].filter { !$0.isEmpty }.joined(separator: " → ")
            return "\(compiled.blockCount) blocks" + (parts.isEmpty ? "" : "   \(parts)")
        }
        if let error = diagnostics.first { return "Line \(error.line): \(error.message)" }
        return failure ?? "Not compiled"
    }

    // MARK: - Report

    private var reportPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let document = documentName {
                    Text("Open document: \(document)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(isEmpty ? "No source" : (compiled == nil ? "Problems" : "Compiled"))
                    .font(.headline)

                if isEmpty { emptyState }

                if !outlineRows.isEmpty { outlineView }

                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if diagnostics.isEmpty {
                    if let compiled {
                        summary(compiled)
                    } else {
                        Text("Compiles as you type.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    diagnosticList
                }

                Divider()

                Text("The source is IEC 61131-3 Structured Text. A \(Text("PROGRAM").font(.system(.callout, design: .monospaced))) is a page, a \(Text("FUNCTION_BLOCK").font(.system(.callout, design: .monospaced))) a macro, pins are \(Text("AT %IX0").font(.system(.callout, design: .monospaced))) / \(Text("AT %QX0").font(.system(.callout, design: .monospaced))), and \(Text("IF").font(.system(.callout, design: .monospaced))) becomes a selection of wires.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(minWidth: 280, idealWidth: 330, maxWidth: 440)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let document = documentName {
                Text("‘\(document)’ has no Structured Text source: a .pcc stores blocks and wires, not the text that produced them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Writing a program here and pressing Open in Wirebench replaces the open document; the file on disk is untouched until you save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Write a program, or open a project and recover its source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Recover from the open project") { recoverFromProject() }
                .buttonStyle(.bordered)
                .disabled(model.project == nil)
        }
    }

    private var outlineView: some View {
        DisclosureGroup("Declarations") {
            ForEach(outlineRows.indices, id: \.self) { index in
                Button(outlineRows[index].label) { jumpLine = outlineRows[index].line }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var diagnosticList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Button {
                    jumpLine = diagnostic.line
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Line \(diagnostic.line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(diagnostic.message)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func summary(_ compiled: CompiledSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(compiled.blockCount) blocks from \(compiled.program)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
            if !compiled.variables.isEmpty {
                Text("State: \(compiled.variables.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Pages: \(compiled.pages.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Open it in Wirebench to look at the sheet, run it, or compile it to a program.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.swiftSource.contains("(* Not recovered:") || model.swiftSource.contains("(* Conditional blocks") {
                Label("This sheet has blocks the subset cannot express; compiling replaces it with what is here.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Recover from Project", systemImage: "arrow.down.doc") { recoverFromProject() }
                .disabled(model.project == nil)
                .help("Write the open project's blocks back into source")
            Button("Compile", systemImage: "hammer") { rebuild() }
                .keyboardShortcut("r", modifiers: .command)
                .help("Compile the source (⌘R)")
            Button("Open in Wirebench", systemImage: "arrow.up.forward.app") { openInWirebench() }
                .disabled(compiled == nil)
                .help("Replace the open document with the compiled project")
            Button("Save .pcc…", systemImage: "square.and.arrow.down") { save() }
                .disabled(compiled == nil)
                .help("Save the compiled project as a .pcc file")
        }
    }

    private func openInWirebench() {
        guard let compiled else { return }
        let hadChanges = model.hasSignificantChanges
        model.requestAdopt(compiled.project)
        if !hadChanges { model.zoomToFit() }
        NSApp.activate(ignoringOtherApps: true)
        // The document lives in the main window; this one keeps the source for the next edit.
        if let document = NSApp.windows.first(where: { $0.canBecomeMain && $0.title != "Structured Text" }) {
            document.makeKeyAndOrderFront(nil)
        }
    }

    private func save() {
        guard let compiled else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pccProject]
        panel.nameFieldStringValue = "\(compiled.project.name).pcc"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try PCCSerializer().serialize(project: compiled.project).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                savingError = error.localizedDescription
            }
        }
    }

    // MARK: - Compiling

    private func scheduleRebuild() {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            rebuild()
        }
    }

    /// Recovers the open project's source: the pages, pins and logic the subset can express.
    private func recoverFromProject() {
        guard let project = model.project else { return }
        model.swiftSource = PCCDecompiler().source(for: project, named: documentName)
    }

    /// The open document's name: the file's, or the project's when it has one.
    private var documentName: String? {
        if let url = model.currentFileURL { return url.deletingPathExtension().lastPathComponent }
        let name = model.project?.name ?? ""
        return name.isEmpty ? nil : name
    }

    private func rebuildEmpty() {
        spans = []
        outlineRows = []
        compiled = nil
        diagnostics = []
        failure = nil
    }

    private func rebuild() {
        spans = SourceHighlighter.spans(in: model.swiftSource)
        if let program = try? SourceParser.parse(model.swiftSource) {
            var rows: [(String, Int)] = []
            for unit in program.units {
                rows.append(("\(unit.kind == .functionBlock ? "FUNCTION_BLOCK" : "PROGRAM") \(unit.name)", unit.line))
                for pin in unit.pins {
                    rows.append(("\(pin.name) AT %\(pin.direction == .input ? "I" : "Q")X\(pin.index) : BOOL", pin.line))
                }
                for variable in unit.variables { rows.append(("\(variable.name) : BOOL", variable.line)) }
                for instance in unit.instances { rows.append(("\(instance.name) : \(instance.typeName)", instance.line)) }
            }
            outlineRows = rows
        } else {
            outlineRows = []
        }
        do {
            let result = try SourceCompiler().compile(model.swiftSource, projectName: "Untitled")
            compiled = result
            diagnostics = []
            failure = nil
        } catch let error as SourceError {
            compiled = nil
            diagnostics = [error]
            failure = nil
        } catch {
            compiled = nil
            diagnostics = []
            failure = error.localizedDescription
        }
    }
}
