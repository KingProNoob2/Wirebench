import Foundation

/// Where the `.pcc` corpus lives, and the one place that knows.
///
/// The projects moved once already — `School/Informační a Řídící Systémy/Dirigo` became
/// `School/IRS/Dirigo` — and nine separate files hardcoded the old path, so a folder rename broke the
/// whole suite with nineteen failures that said only "file not found". The directory is not part of this
/// checkout and its name is not this project's to fix, so the lookup tries the known spellings instead
/// of assuming one.
///
/// A missing corpus makes dependent tests skip rather than fail: it is an environment fact, not a
/// defect in the code under test. Sweeps that must not silently pass on an empty set assert their own
/// minimum count, which is the right place for that check.
enum TestCorpus {
    /// Every directory the corpus has been seen in, most likely first.
    static let directories: [URL] = [
        // The current name. `IRS` is the abbreviation the folder was renamed to.
        nextcloud("School/IRS/Dirigo"),
        // The original, fully spelled out — kept in case the rename is reverted.
        nextcloud("School/Informační a Řídící Systémy/Dirigo"),
        nextcloud("School/PCV"),
        nextcloud("School"),
        // `had.pcc` and `had+1block.pcc` have also lived beside the code.
        workspace,
    ]

    private static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DirigoSwiftTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // DirigoSwift
            .deletingLastPathComponent()   // the checkout's parent
    }

    private static func nextcloud(_ path: String) -> URL {
        URL(fileURLWithPath: "/Users/erik/Nextcloud").appendingPathComponent(path)
    }

    /// The project called `name`, wherever it is. `nil` when the corpus is not on this machine.
    static func project(named name: String) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The project called `name` in the first directory that holds it.
    ///
    /// Returns `nil` rather than a path that does not exist, so a caller's `fileExists` check keeps
    /// working unchanged.
    static func existing(_ name: String) -> URL? { project(named: name) }
}
