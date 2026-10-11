import SwiftUI
import UniformTypeIdentifiers
import DirigoCore

extension UTType {
    /// Dirigo's project format.
    ///
    /// Named here rather than exported from an `Info.plist` because all the app needs it for is to
    /// label a file panel.
    static var pccProject: UTType { UTType(filenameExtension: "pcc") ?? .xml }

    /// Dirigo's program binary, what *Program Binary…* writes and the uploader sends.
    static var programBinary: UTType { UTType(filenameExtension: "pbd") ?? .data }
}

/// A minimal `FileDocument` so SwiftUI can present a save panel.
///
/// It is deliberately **not** the source of the bytes. A `.pcc` records its own path in
/// `PROJECT_PATH`, so the file has to be written against the destination the user just chose — which
/// is only known once the panel returns. The completion handler therefore writes through the model,
/// and this type exists to give `fileExporter` something that names the format.
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
