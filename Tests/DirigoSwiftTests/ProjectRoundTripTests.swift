import Testing
import Foundation
import DirigoCore

/// The byte-identical round-trip, checked against every `.pcc` on this machine rather than one
/// fixture.
///
/// This is the property the whole port rests on: opening a project and saving it must not change a
/// single byte, or the editor becomes something you cannot safely use on real work. Sweeping the
/// user's own files is what found `APPLICATION_PATH="" PROJECT_PATH="" ORIG_PROJECT_PATH=""` being
/// emitted unconditionally — 57 bytes added to every project that did not carry those attributes.
@Suite("Project round-trip")
struct ProjectRoundTripTests {
    /// Written by an earlier revision of this serializer, so it is not evidence about Dirigo's own
    /// format. Excluded by name and kept visible rather than silently dropped.
    static let notAuthoredByDirigo: Set<String> = ["ruleta_kostka_had.pcc"]

    static var projectFiles: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var found: [URL] = []
        for base in [root, root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()] {
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "pcc" { found.append(url) }
        }
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    @Test("Every project on disk is saved back byte-for-byte")
    func byteIdentical() throws {
        let files = Self.projectFiles.filter { !Self.notAuthoredByDirigo.contains($0.lastPathComponent) }
        guard !files.isEmpty else { return }
        #expect(files.count >= 2, "expected at least the workspace's own projects, found \(files.count)")

        var differing: [String] = []
        for url in files {
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let project = try? PCCParser().parse(xmlString: original) else {
                differing.append("\(url.lastPathComponent): failed to parse")
                continue
            }
            let output = PCCSerializer().serialize(project: project)
            if output != original {
                let a = Array(original), b = Array(output)
                var i = 0
                while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
                differing.append("\(url.lastPathComponent): differs at byte \(i) of \(a.count)/\(b.count)")
            }
        }
        #expect(differing.isEmpty,
                "projects that did not survive a save unchanged:\n\(differing.joined(separator: "\n"))")
    }
}
