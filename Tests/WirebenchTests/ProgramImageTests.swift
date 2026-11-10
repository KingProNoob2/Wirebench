import Testing
import Foundation
@testable import WirebenchHardware

/// These tests run against a **real export** from Dirigo (`had.pbd` / `had.dmp`, exported from
/// `had.pcc` by the user). That is the point of them: the container format was recovered from the
/// disassembly, and this is the artefact that can confirm or falsify it.
@Suite("Program image container")
struct ProgramImageTests {

    /// The workspace root, three levels up from this file.
    static var workspace: URL {
        URL(fileURLWithPath: #filePath)          // .../Wirebench/Tests/WirebenchTests/x.swift
            .deletingLastPathComponent()          // .../Wirebench/Tests/WirebenchTests
            .deletingLastPathComponent()          // .../Wirebench/Tests
            .deletingLastPathComponent()          // .../Wirebench
            .deletingLastPathComponent()          // .../dirigo-antigravity  (the workspace root)
    }

    @Test("A real .pbd parses into the header, the project name and the id/length blocks")
    func realExportParses() throws {
        let url = Self.workspace.appendingPathComponent("had.pbd")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "had.pbd is not present — this test needs the user's export")

        let image = try PLCProgramImage.load(contentsOf: url)

        // The decompressed size is fixed by the block arithmetic; 256 + (8+264) + (8+8) = 544.
        #expect(image.serialized().count == 544, "the size the real file decompresses to")
        #expect(image.projectName == "had.pcc", "the name is a short string at header +0x10")

        #expect(image.blocks.count == 2)
        #expect(image.blocks.map(\.id) == [0x20D, 0x21C],
                "525 and 540 — the two ExportFileProgramBinary immediates")
        // The length excludes the eight-byte prefix: 8 + 256 = 264.
        #expect(image.blocks[0].payload.count == 264)
        #expect(image.blocks[1].payload.count == 8)
    }

    @Test("The 525 block carries the section exported separately as had.dmp")
    func blockCarriesTheSection() throws {
        let pbd = Self.workspace.appendingPathComponent("had.pbd")
        let dmp = Self.workspace.appendingPathComponent("had.dmp")
        try #require(FileManager.default.fileExists(atPath: pbd.path) && FileManager.default.fileExists(atPath: dmp.path),
                     "this test needs both of the user's exports")

        let image = try PLCProgramImage.load(contentsOf: pbd)
        let section = [UInt8](try Data(contentsOf: dmp))
        #expect(section.count == 256)

        // The block's payload is an 8-byte sub-header followed by the section, byte for byte.
        let payload = image.blocks[0].payload
        #expect(payload.count == 8 + section.count)
        #expect(Array(payload.suffix(section.count)) == section,
                "had.dmp is exactly the 525 block's data")

        // And that data ends with the profile name, space-padded to 32 bytes.
        let name = String(decoding: section[0xD4..<0xF4], as: UTF8.self)
        #expect(name.hasPrefix("Sybas Control P3"))
        #expect(name.count == 32)
    }

    @Test("A parse is reversible")
    func roundTrip() throws {
        let url = Self.workspace.appendingPathComponent("had.pbd")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs the user's export")
        let original = try PLCProgramImage.load(contentsOf: url)
        let again = try PLCProgramImage.parse(original.serialized())
        #expect(again == original)
    }

    @Test("A table wrapped by this app is the container Dirigo itself writes")
    func writerMatchesTheRealExport() throws {
        let url = Self.workspace.appendingPathComponent("had.pbd")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let real = [UInt8](try Data(contentsOf: url))
        let inflated = try PLCProgramImage.inflate(real)
        let image = try PLCProgramImage.parse(inflated)

        // The table section is the sub-header and then the 256-byte table, which `had.dmp` also is.
        let table = try #require(image.blocks.first { $0.id == PLCProgramImage.programTableSection })
        #expect(table.payload.count == 264)
        #expect(Array(table.payload[8...]) == [UInt8](try Data(contentsOf: Self.workspace.appendingPathComponent("had.dmp"))))
        #expect(Array(table.payload[0..<8]) == PLCProgramImage.tableSectionHeader)

        // Wrapping the same table with the same header must reproduce the file's container exactly — the
        // compressed bytes may differ, the bytes inside may not.
        let mine = try PLCProgramImage.programBinary(table: Array(table.payload[8...]),
                                                     projectName: image.projectName,
                                                     header: image.header)
        #expect(mine[0] == 0x78 && mine[1] == 0x9C, "a real export starts 78 9C")
        // The zlib trailer is the Adler-32 of the uncompressed bytes, big-endian. Comparing it with the
        // real export's own trailer is what catches a framing mistake: Apple's inflate ignores this field,
        // so a round trip through it alone would accept a wrong one (as it did once).
        #expect(mine.suffix(4) == real.suffix(4), "the Adler-32 trailer must match Dirigo's")
        #expect(try PLCProgramImage.inflate(mine) == inflated)
        let roundTrip = try PLCProgramImage.parse(try PLCProgramImage.inflate(mine))
        #expect(roundTrip.blocks == image.blocks)
        #expect(roundTrip.projectName == image.projectName)
    }

    @Test("The default header round-trips and names the project")
    func defaultHeader() throws {
        let table = [UInt8](repeating: 0xAB, count: 256)
        let file = try PLCProgramImage.programBinary(table: table, projectName: "kosticka.pcc")
        let image = try PLCProgramImage.parse(try PLCProgramImage.inflate(file))
        #expect(image.projectName == "kosticka.pcc")
        #expect(image.blocks.count == 2)
        #expect(image.blocks[0].id == PLCProgramImage.programTableSection)
        #expect(image.blocks[0].payload.count == 264)
        #expect(Array(image.blocks[0].payload[8...]) == table)
        #expect(image.blocks[1].id == PLCProgramImage.trailerSection)
        #expect(image.blocks[1].payload == PLCProgramImage.trailerPayload)
        // And a header built by hand has the name where a real one does.
        let header = PLCProgramImage.defaultHeader(projectName: "kosticka.pcc")
        #expect(header[PLCProgramImage.nameOffset] == 12)          // "kosticka.pcc" is twelve bytes
        #expect(String(decoding: header[PLCProgramImage.nameOffset + 1..<PLCProgramImage.nameOffset + 13],
                       as: UTF8.self) == "kosticka.pcc")
    }

    @Test("Truncated and malformed input is refused, not guessed at")
    func malformedIsRefused() {
        #expect(throws: PLCProgramImage.ParseError.tooShort) { try PLCProgramImage.parse([0, 1, 2]) }
        // A header whose name length runs past the header.
        var header = [UInt8](repeating: 0, count: PLCProgramImage.headerSize)
        header[PLCProgramImage.nameOffset] = 0xFF
        #expect(throws: PLCProgramImage.ParseError.badName) { try PLCProgramImage.parse(header) }
        // A block claiming more than is present.
        var short = [UInt8](repeating: 0, count: PLCProgramImage.headerSize)
        short.append(contentsOf: [0x0D, 0x02, 0x00, 0x00])   // id 525
        short.append(contentsOf: [0xFF, 0x00, 0x00, 0x00])   // length 255, but nothing follows
        #expect(throws: PLCProgramImage.ParseError.self) { try PLCProgramImage.parse(short) }
    }
}
