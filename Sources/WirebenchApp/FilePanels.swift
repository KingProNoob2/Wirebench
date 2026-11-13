import WirebenchModel
import SwiftUI
import UniformTypeIdentifiers
import WirebenchCore

extension UTType {
    /// Wirebench's own project format: JSON, declared in the app's `Info.plist`.
    static var wirebenchProject: UTType {
        UTType(filenameExtension: "wbp") ?? UTType(exportedAs: "com.wirebench.project", conformingTo: .json)
    }

    /// Maraflow's project format, read-only: `.mfl` is imported and saved as `.wbp`.
    static var maraflowProject: UTType { UTType(filenameExtension: "mfl") ?? .xml }

    /// Dirigo's project format, kept for reading legacy files and for the legacy export.
    ///
    /// Named here rather than exported from an `Info.plist` because all the app needs it for is to
    /// label a file panel.
    static var pccProject: UTType { UTType(filenameExtension: "pcc") ?? .xml }

    /// Dirigo's program binary, what *Program Binary…* writes and the uploader sends.
    static var programBinary: UTType { UTType(filenameExtension: "pbd") ?? .data }

    /// Dirigo's variables file, the dBase III table it writes beside a project.
    static var dbaseTable: UTType { UTType(filenameExtension: "dbf") ?? .data }
}

/// A minimal `FileDocument` so SwiftUI can present the normal save panel.
///
/// It is deliberately **not** the source of the bytes: the document is written by the model against the
/// destination the panel returns, so every save goes through one code path.
struct WirebenchSaveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wirebenchProject] }
    static var writableContentTypes: [UTType] { [.wirebenchProject] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

/// The save panel for a Maraflow export.
struct MaraflowSaveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.maraflowProject] }
    static var writableContentTypes: [UTType] { [.maraflowProject] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

/// The save panel for the legacy export. Its bytes are written by the model too, for the same reason; a `.pcc`
/// records its own path in `PROJECT_PATH`, which is only known once the panel returns.
struct LegacySaveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pccProject] }
    static var writableContentTypes: [UTType] { [.pccProject] }

    var xml: String

    init(xml: String = "") {
        self.xml = xml
    }

    /// Builds a document for the project as it stands, so the panel opens with real content.
    init(project: PCCProject?) {
        guard let project else {
            self.xml = ""
            return
        }
        self.xml = PCCSerializer().serialize(project: project)
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.xml = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(xml.utf8))
    }
}

/// A save panel that only names the program-binary format.
///
/// Like `LegacySaveDocument`, the bytes are not produced here: a build's output is written by the model
/// against the destination the panel returns, so there is one code path for what lands on disk.
struct ProgramBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.programBinary] }
    static var writableContentTypes: [UTType] { [.programBinary] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

/// The same, for the generated symbol table.
struct SymbolTableDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

/// The same, for the variables `.dbf`.
struct ProgramVariablesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.dbaseTable] }
    static var writableContentTypes: [UTType] { [.dbaseTable] }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

/// What happens when a save panel comes back, shared by every exporter.
enum SavePanelResult {
    /// A panel dismissed with Escape or Cancel reports `userCancelled`; the app did nothing wrong.
    static func isUserCancelled(_ error: Error) -> Bool {
        (error as NSError).code == NSUserCancelledError
    }

    /// An exporter's completion: where it was written goes to `use`; a failure is reported as `kind`.
    /// Cancelling is not a failure to report — but the save question that opened the panel has to hear
    /// about it (`onNoDestination`), or the quit it was holding would never be answered. Any failure,
    /// not only a cancellation, means no file was written, so the question is answered either way.
    static func completion(model: AppModel, failure: String, kind: AppModel.PendingAlert.Kind = .warning,
                           onNoDestination: (() -> Void)? = nil,
                           _ use: @escaping (URL) -> Void) -> (Result<URL, Error>) -> Void {
        { result in
            switch result {
            case .success(let url): use(url)
            case .failure(let error):
                if !isUserCancelled(error) {
                    model.presentMessage(title: failure, message: error.localizedDescription, kind: kind)
                }
                onNoDestination?()
            }
        }
    }
}

/// The save panels a build opens — program binary, symbol table, variables.
///
/// A window shows one sheet at a time, and a save panel is a sheet: opened from the view *behind* the build
/// report, it waits — invisibly — until the report is closed. So the report carries its own copy of these
/// panels, and the main view's copy stands down while the report is up. `inReport` says which copy this is.
private struct BuildExportPanels: ViewModifier {
    let model: AppModel
    let inReport: Bool

    func body(content: Content) -> some View {
        content
            .fileExporter(isPresented: binding(.exportProgramBinary),
                          document: ProgramBinaryDocument(),
                          contentType: .programBinary,
                          defaultFilename: model.programBinaryDefaultName,
                          onCompletion: SavePanelResult.completion(model: model, failure: "Could not export the program") {
                              model.finishProgramBinaryExport(to: $0)
                          })
            .fileExporter(isPresented: binding(.exportSymbolTable),
                          document: SymbolTableDocument(),
                          contentType: .commaSeparatedText,
                          defaultFilename: model.symbolTableDefaultName,
                          onCompletion: SavePanelResult.completion(model: model, failure: "Could not export the symbol table") {
                              model.finishSymbolTableExport(to: $0)
                          })
            .fileExporter(isPresented: binding(.exportProgramVariables),
                          document: ProgramVariablesDocument(),
                          contentType: .dbaseTable,
                          defaultFilename: model.programVariablesDefaultName,
                          onCompletion: SavePanelResult.completion(model: model, failure: "Could not export the variables") {
                              model.finishProgramVariablesExport(to: $0)
                          })
    }

    private func binding(_ panel: AppModel.FilePanel) -> Binding<Bool> {
        Binding(get: { model.isPresenting(panel, inReport: inReport) },
                set: { presented in if !presented { model.pendingFilePanel = nil } })
    }
}

extension View {
    /// The build's save panels, for the main view (`inReport: false`) or the build report (`true`).
    func buildExportPanels(_ model: AppModel, inReport: Bool) -> some View {
        modifier(BuildExportPanels(model: model, inReport: inReport))
    }
}

