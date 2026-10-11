import Testing
import Foundation
@testable import DirigoHardware

/// Against the user's real export (`had.dmp`), whose bytes also appear inside the captured upload.
@Suite("Program table")
struct ProgramTableTests {
    static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func realTable() throws -> PLCProgramTable {
        let url = workspace.appendingPathComponent("had.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs the user's export")
        return try PLCProgramTable(bytes: [UInt8](try Data(contentsOf: url)))
    }

    @Test("A real table parses and re-emits byte for byte")
    func roundTrip() throws {
        let table = try Self.realTable()
        #expect(table.bytes.count == 256)
        // Re-emitting is the property that matters: nothing may be lost or reordered.
        #expect(try PLCProgramTable(bytes: table.bytes).bytes == table.bytes)
    }

    @Test("The established fields hold in the real table")
    func fields() throws {
        let table = try Self.realTable()
        #expect(table.version == 1, "movw $0x1 at 0x4B0A07")
        #expect(table.projectFlags == (7, 1, 1), "the three project bytes from Compile")
        #expect(table.sentinel == 0xFFFF, "the module table's terminator")
        #expect(table.dataLength == (0xD0, 0xD0), "recorded twice, and equal to its own offset")
        #expect(table.profileName == "Sybas Control P3", "the padded 32-byte profile name")
        // The checksum is carried, not computed. Pinned so a change to the file is noticed.
        #expect(table.checksum == 0xD5E0)
    }

    @Test("The real length is the recorded one, not the file's padding")
    func realLength() throws {
        let table = try Self.realTable()
        // 0xD0 = 208 is recorded twice at 0xD0, so the 256-byte file is padded.
        #expect(table.realLength == 208)
        #expect(table.uploadedBytes.count == 208)
        #expect(table.uploadedBytes == Array(table.bytes.prefix(208)))
    }

    @Test("A matrix payload matches what the captured upload carried")
    func matrixPayloadMatchesCapture() throws {
        let table = try Self.realTable()
        let first = table.matrixWritePayload(byteOffset: 0, columns: 8,
                                             data: Array(table.uploadedBytes.prefix(128)))
        // From message.txt: 02 20 0D 02 00 00 00 00 08 00 08 00, then the table's first eight bytes.
        #expect(Array(first.prefix(12)) == [0x02, 0x20, 0x0D, 0x02, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00])
        #expect(Array(first[12..<20]) == [UInt8](arrayLiteral: 0x00, 0x00, 0x01, 0x00, 0x07, 0x00, 0x01, 0x01))
        #expect(first.count == 12 + 128)

        // The second frame in the capture is Col = 8, NCols = 4 — byte 128 at a 16-byte stride.
        let second = table.matrixWritePayload(byteOffset: 128, columns: 4,
                                              data: Array(table.uploadedBytes[128..<192]))
        #expect(Array(second[4..<12]) == [UInt8](arrayLiteral: 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x00),
                "Col 8, Row 0, NCols 4, NRows 8 — the captured second frame")
    }

    @Test("The table is split into column chunks, as the uploader does")
    func framesSplit() throws {
        let table = try Self.realTable()
        let frames = table.matrixWriteFrames(rows: 8, chunkBytes: 128)
        // 208 bytes: 128 then 80, i.e. 8 columns then 5.
        #expect(frames.count == 2)
        #expect(frames[0].count == 12 + 128)
        #expect(frames[1].count == 12 + 80)
        #expect(Array(frames[1][4..<12]) == [UInt8](arrayLiteral: 0x08, 0x00, 0x00, 0x00, 0x05, 0x00, 0x08, 0x00),
                "Col 8, Row 0, NCols 5, NRows 8")
        // Concatenated, the frames' data is the table and nothing else.
        let data = frames.map { Array($0[12...]) }.flatMap { $0 }
        #expect(data == table.uploadedBytes)
    }

    @Test("A table of the wrong size is refused")
    func wrongSize() {
        #expect(throws: PLCProgramTable.ParseError.wrongSize(255)) {
            try PLCProgramTable(bytes: [UInt8](repeating: 0, count: 255))
        }
    }

    // MARK: - The uploader

    /// Answers the way the PLC does, so the sequence can be checked without hardware.
    private final class Recorder: DbNetTransport {
        private(set) var sent: [[UInt8]] = []
        func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
            sent.append(frame)
            guard case .success(let request) = DbNetFrame.parseSerial(frame) else { return [] }
            // The short-form reply the capture shows the PLC sending, with an OK status byte.
            return DbNetFrame.encodeSerial(destination: request.source,
                                           source: request.destination,
                                           function: 0x00)
        }
    }

    @Test("The upload stops the PLC, writes the table in frames, then starts it")
    func uploadSequence() throws {
        let table = try Self.realTable()
        let recorder = Recorder()
        let session = DbNetSession(transport: recorder, address: 1)
        let uploader = PLCUploader(session: session, destination: 1, source: 31)
        uploader.stopWait = 0
        uploader.startWait = 0

        let frames = try uploader.upload(table: table)
        #expect(frames == 2)

        // stop, two matrix frames, start — and each is a serial frame with the recovered layout.
        try #require(recorder.sent.count == 4)
        let parsed = try recorder.sent.map { bytes -> DbNetFrame.SerialFrame in
            switch DbNetFrame.parseSerial(bytes) {
            case .success(let f): return f
            case .failure(let why): throw why
            }
        }
        // The stop write: type, station, 0x45, then 02 00 C0 03 01 00 — 960 = 1.
        #expect(parsed[0].function == 0x45)
        #expect(Array(parsed[0].data.prefix(6)) == [UInt8](arrayLiteral: 0x02, 0x00, 0xC0, 0x03, 0x01, 0x00))
        // The start write: the same, with the value 0.
        #expect(Array(parsed[3].data.prefix(6)) == [UInt8](arrayLiteral: 0x02, 0x00, 0xC0, 0x03, 0x00, 0x00))
        // And the middle two carry the table.
        #expect(parsed[1].destination == 1 && parsed[1].source == 31)
        #expect(Array(parsed[1].data.prefix(4)) == [UInt8](arrayLiteral: 0x02, 0x20, 0x0D, 0x02),
                "the matrix payload names WID 525")
    }

    @Test("The computed checksum matches the real exports")
    func checksumMatchesRealFiles() throws {
        let workspace = Self.workspace
        for name in ["had.dmp", "had+1block.dmp"] {
            let url = workspace.appendingPathComponent(name)
            try #require(FileManager.default.fileExists(atPath: url.path), "\(name) is not present")
            let table = try PLCProgramTable(bytes: [UInt8](try Data(contentsOf: url)))
            #expect(table.checksumIsValid,
                    "\(name): stored 0x\(String(table.checksum, radix: 16)) vs computed 0x\(String(table.computedChecksum, radix: 16))")
        }
    }

    @Test("A single flipped byte invalidates the checksum")
    func checksumDetectsDamage() throws {
        let table = try Self.realTable()
        #expect(table.checksumIsValid)
        var damaged = table.bytes
        damaged[0x40] ^= 0x01                     // one bit in the module table
        let modified = try PLCProgramTable(bytes: damaged)
        #expect(!modified.checksumIsValid, "the field must depend on the whole table")
    }
}
