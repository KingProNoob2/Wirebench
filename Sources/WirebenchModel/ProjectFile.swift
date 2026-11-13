import Foundation
import WirebenchCore

/// A project file on disk, in the current format, Dirigo's legacy `.pcc`, or Maraflow's `.mfl`.
public enum ProjectFileFormat: String, Sendable {
    case wirebench
    case dirigo
    case maraflow
}

public struct ImportedProject {
    public let project: PCCProject
    public let format: ProjectFileFormat
    /// What an importer had to approximate or leave out; empty for the native format.
    public let notes: [String]
}

/// Reads any project format Wirebench supports and writes the current one. Format detection is by content, not only
/// by extension, so a `.pcc` holding JSON still opens and a `.wbp` holding XML is treated as a legacy import.
public enum ProjectFile {
    public static let fileExtension = WirebenchDocument.fileExtension

    public static func read(at url: URL) throws -> ImportedProject {
        let data = try Data(contentsOf: url)
        return try read(data: data, filename: url.deletingPathExtension().lastPathComponent)
    }

    public static func read(data: Data, filename: String = "Untitled") throws -> ImportedProject {
        if WirebenchDocument.looksLikeDocument(data) {
            return ImportedProject(project: try WirebenchDocument.decode(data), format: .wirebench, notes: [])
        }
        if MaraflowDocument.looksLikeDocument(data) {
            let outcome = try MaraflowImporter.importProject(data: data, filename: filename)
            return ImportedProject(project: outcome.project, format: .maraflow, notes: outcome.notes)
        }
        return ImportedProject(project: try PCCParser().parse(data: data), format: .dirigo, notes: [])
    }

    public static func write(_ project: PCCProject, to url: URL) throws {
        try WirebenchDocument.encode(project).write(to: url, options: .atomic)
    }
}
