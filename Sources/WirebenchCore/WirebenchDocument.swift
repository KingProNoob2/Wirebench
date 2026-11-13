import Foundation

/// Wirebench's own project format: a small JSON envelope around `PCCProject`.
///
/// The envelope is what makes the file identifiable and versionable; the project inside is the editor's model,
/// encoded so that everything a legacy export needs — attribute order, unknown sections, comments, raw XML children —
/// survives. JSON is chosen because projects are small, it is diffable, and both the app and the command line already
/// speak it without a codec dependency.
///
/// The keys of `PCCProject` and its nested types are schema version 1. A change to one of them is a format change and
/// must bump `currentVersion` and add a migration in `decode`; unknown keys are ignored, so additive changes are
/// forward-compatible for readers that know the same version.
public struct WirebenchDocument: Codable, Sendable, Equatable {
    public static let formatName = "wirebench-project"
    public static let currentVersion = 1
    public static let fileExtension = "wbp"

    /// Identifies the format itself, so a random JSON file is rejected with a clear error.
    public var format: String
    /// The schema version of `project`. See `currentVersion`.
    public var formatVersion: Int
    public var project: PCCProject

    public init(project: PCCProject) {
        self.format = Self.formatName
        self.formatVersion = Self.currentVersion
        self.project = project
    }

    /// Pretty-printed, sorted, with a trailing newline: a file that reads and diffs well.
    public static func encode(_ project: PCCProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(WirebenchDocument(project: project))
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> PCCProject {
        let document: WirebenchDocument
        do {
            document = try JSONDecoder().decode(WirebenchDocument.self, from: data)
        } catch {
            throw WirebenchDocumentError.notADocument(reason: error.localizedDescription)
        }
        guard document.format == formatName else {
            throw WirebenchDocumentError.foreignFormat(document.format)
        }
        guard document.formatVersion == currentVersion else {
            throw WirebenchDocumentError.unsupportedVersion(document.formatVersion)
        }
        return document.project
    }

    /// Whether `data` looks like this format: a JSON object (the parser then decides whether it is ours). Used to
    /// choose between a `.wbp` and a legacy `.pcc` when a file's name is not enough.
    public static func looksLikeDocument(_ data: Data) -> Bool {
        var index = data.startIndex
        if data.count >= 3, data[data.startIndex..<data.index(data.startIndex, offsetBy: 3)] == Data([0xEF, 0xBB, 0xBF]) {
            index = data.index(data.startIndex, offsetBy: 3)
        }
        while index < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[index]) {
            index = data.index(after: index)
        }
        return index < data.endIndex && data[index] == UInt8(ascii: "{")
    }
}

public enum WirebenchDocumentError: Error, LocalizedError, Equatable {
    case notADocument(reason: String)
    case foreignFormat(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notADocument:
            return "This is not a Wirebench project: the file is not a JSON document with the expected fields."
        case .foreignFormat(let format):
            return "This JSON file belongs to the format '\(format)', not to a Wirebench project."
        case .unsupportedVersion(let version):
            return "This project uses \(WirebenchDocument.formatName) version \(version); this build reads version "
                + "\(WirebenchDocument.currentVersion). Update Wirebench to open it."
        }
    }
}

/// A project file on disk, in either the current format or Dirigo's legacy `.pcc`.
public enum ProjectFileFormat: String, Sendable {
    case wirebench
    case dirigo
}

/// Reads either format and writes the current one. Format detection is by content, not only by extension, so a
/// `.pcc` holding JSON still opens and a `.wbp` holding XML is treated as a legacy import.
public enum ProjectFile {
    public static let fileExtension = WirebenchDocument.fileExtension

    public static func read(at url: URL) throws -> (project: PCCProject, format: ProjectFileFormat) {
        let data = try Data(contentsOf: url)
        if WirebenchDocument.looksLikeDocument(data) {
            return (try WirebenchDocument.decode(data), .wirebench)
        }
        return (try PCCParser().parse(data: data), .dirigo)
    }

    public static func write(_ project: PCCProject, to url: URL) throws {
        try WirebenchDocument.encode(project).write(to: url, options: .atomic)
    }
}
