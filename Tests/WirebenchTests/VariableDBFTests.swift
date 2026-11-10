import Testing
import Foundation
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel
@testable import WirebenchHardware

/// The variables `.dbf`, against the five real files Dirigo wrote rather than against a description of
/// the format.
///
/// The encoding has two traps this suite exists to hold. Numbers are big-endian with the sign bit
/// flipped, so reading them the obvious way gives nonsense (`ID = 1101` is `80 00 04 4D`). And all-zero
/// bytes mean *not set*, which is not the same as zero — a real `0` is `80 00 00 00`. Get either wrong
/// and the file still parses in a dBase reader, with wrong numbers in it.
@Suite("The variables .dbf")
struct VariableDBFTests {
    /// The workspace root, which is where Dirigo's own `.dbf` files live (one beside its project, four
    /// more under `Serial packet capture/`).
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every real `.dbf` in the workspace, with its `.csv` sibling.
    static var realFiles: [(dbf: URL, csv: URL)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return (walker.compactMap { $0 as? URL })
            .filter { $0.pathExtension.lowercased() == "dbf" }
            .compactMap { url in
                let csv = url.deletingPathExtension().appendingPathExtension("csv")
                guard FileManager.default.fileExists(atPath: csv.path) else { return nil }
                return (dbf: url, csv: csv)
            }
            .sorted { $0.dbf.path < $1.dbf.path }
    }

    /// The stamp a real file carries, so a comparison can be byte for byte including the three date
    /// bytes — the header's date is the day Dirigo wrote it, not anything about the project.
    static func stamp(of bytes: [UInt8]) throws -> PLCVariableDBF.DateStamp {
        try #require(PLCVariableDBF.DateStamp(bytes: Array(bytes.prefix(4))),
                     "a real .dbf should carry a readable header date")
    }

    @Test("Every real variables file is reproduced byte for byte")
    func encodesTheRealFiles() throws {
        let files = Self.realFiles
        // A sweep that finds nothing must not look like a sweep that found everything correct.
        #expect(files.count >= 5, "expected the workspace's five real .dbf files, found \(files.count)")

        for file in files {
            let real = try Data(contentsOf: file.dbf)
            let csv = try String(contentsOf: file.csv, encoding: .utf8)
            let rows = PLCProjectCompiler.symbols(fromSymbolCSV: csv)
            #expect(!rows.isEmpty, "\(file.csv.lastPathComponent) should have rows")

            let written = PLCVariableDBF.bytes(fromSymbols: rows, exportedOn: try Self.stamp(of: Array(real)))
            #expect(written == Array(real),
                    "\(file.dbf.lastPathComponent): \(written.count) bytes written, \(real.count) expected")
        }
    }

    @Test("A built project writes the variables file Dirigo wrote")
    @MainActor
    func aBuildWritesTheRealFile() throws {
        let dbfURL = Self.root.appendingPathComponent("had+1block.dbf")
        try #require(FileManager.default.fileExists(atPath: dbfURL.path))
        let real = try Data(contentsOf: dbfURL)

        let model = AppModel()
        model.loadProject(url: Self.root.appendingPathComponent("had+1block.pcc"))
        let report = try #require(model.compileProject(), "the build should have produced a report")

        // From the project, not from the file beside it: this is the whole claim, that compiling
        // `had+1block.pcc` reproduces the table Dirigo exported from it.
        let written = PLCVariableDBF.bytes(fromSymbols: report.symbols,
                                           exportedOn: try Self.stamp(of: Array(real)))
        #expect(written == Array(real),
                "\(written.count) bytes written from the build, \(real.count) in Dirigo's file")
    }

    @Test("Zero and not-set are different bytes")
    func unsetIsNotZero() {
        var zero: [UInt8] = []
        PLCVariableDBF.append(.integer(0), width: 4, into: &zero)
        #expect(zero == [0x80, 0x00, 0x00, 0x00], "a real zero is the sign bit and nothing else")

        var unset: [UInt8] = []
        PLCVariableDBF.append(.unset, width: 4, into: &unset)
        #expect(unset == [0, 0, 0, 0], "an unset column is all zeros, which no value encodes to")

        var one: [UInt8] = []
        PLCVariableDBF.append(.double(1), width: 8, into: &one)
        #expect(one == [0xBF, 0xF0, 0, 0, 0, 0, 0, 0], "K is 1.0 in every real file")

        var zeroDouble: [UInt8] = []
        PLCVariableDBF.append(.double(0), width: 8, into: &zeroDouble)
        #expect(zeroDouble == [0x80] + [UInt8](repeating: 0, count: 7), "Q is 0.0 in every real file")

        // Negative, to pin the sign flip rather than a byte order that happens to agree on positives.
        var minusOne: [UInt8] = []
        PLCVariableDBF.append(.integer(-1), width: 4, into: &minusOne)
        #expect(minusOne == [0x7F, 0xFF, 0xFF, 0xFF], "OWNER is -1 for a module's own row")
    }

    @Test("The descriptors are the twenty columns the csv has, in its order")
    func fieldsFollowTheSymbolColumns() throws {
        let fields = PLCVariableDBF.fields
        #expect(fields.map(\.name) == PLCProjectCompiler.symbolColumns)
        #expect(fields.map { String(UnicodeScalar($0.type)) }.joined() == "IIIIIIICCOOOICCCCCII",
                "the DBF types the csv's quoting already follows")
        #expect(fields.reduce(0) { $0 + $1.width } + 1 == 285, "every real file's record length")
        #expect(32 + 32 * fields.count + 1 == 673, "every real file's header length")
    }
}
