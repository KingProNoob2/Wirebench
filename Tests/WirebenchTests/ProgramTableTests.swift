import Testing
import Foundation
@testable import WirebenchHardware

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
        #expect(table.nameBlockConstant == (0xD0, 0xD0), "recorded twice; a constant of the format, not a length")
        #expect(table.profileName == "Sybas Control P3", "the padded 32-byte profile name")
        // The checksum is carried, not computed. Pinned so a change to the file is noticed.
        #expect(table.checksum == 0xD5E0)
    }

    @Test("The upload is the whole table: a 256-byte table ends a trailer after its sentinel")
    func wholeTable() throws {
        let table = try Self.realTable()
        // The captured uploads send the whole table (192 bytes, and 640 in a newer capture), and the
        // sentinel sits 60 bytes before the end. An earlier reading took a 208-byte prefix instead; the
        // captured 192-byte upload refutes it.
        #expect(table.sentinelOffset == 0xC4)
        #expect(table.bytes.count == table.sentinelOffset + PLCProgramTable.trailerLength)
        #expect(table.uploadedBytes == table.bytes)
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
        // 256 bytes: 128 then 128, i.e. 8 columns then 8.
        #expect(frames.count == 2)
        #expect(frames[0].count == 12 + 128)
        #expect(frames[1].count == 12 + 128)
        #expect(Array(frames[1][4..<12]) == [UInt8](arrayLiteral: 0x08, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00),
                "Col 8, Row 0, NCols 8, NRows 8")
        // Concatenated, the frames' data is the table and nothing else.
        let data = frames.map { Array($0[12...]) }.flatMap { $0 }
        #expect(data == table.uploadedBytes)
    }

    @Test("A table too short to hold a header and trailer is refused")
    func tooShort() {
        #expect(throws: PLCProgramTable.ParseError.tooShort(10)) {
            try PLCProgramTable(bytes: [UInt8](repeating: 0, count: 10))
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
        let frames = try uploader.upload(table: table)
        #expect(frames == 2)

        // GetStatus, stop, read back, two matrix frames, start — each a serial frame with the layout the
        // capture shows.
        try #require(recorder.sent.count == 6)
        let parsed = try recorder.sent.map { bytes -> DbNetFrame.SerialFrame in
            switch DbNetFrame.parseSerial(bytes) {
            case .success(let f): return f
            case .failure(let why): throw why
            }
        }
        // GetStatus is the short form with no data (10 01 1F 49 69 16 in the capture).
        #expect(parsed[0].function == 0x49 && parsed[0].data.isEmpty)
        // The stop write: 02 00 C0 03 01 00 — 960 = 1.
        #expect(parsed[1].function == 0x45)
        #expect(Array(parsed[1].data.prefix(6)) == [UInt8](arrayLiteral: 0x02, 0x00, 0xC0, 0x03, 0x01, 0x00))
        // The read back of the same register: 4D 01 00 C0 03.
        #expect(parsed[2].function == 0x4D)
        #expect(Array(parsed[2].data) == [UInt8](arrayLiteral: 0x01, 0x00, 0xC0, 0x03))
        // The two matrix frames carry the table.
        #expect(parsed[3].destination == 1 && parsed[3].source == 31)
        #expect(Array(parsed[3].data.prefix(4)) == [UInt8](arrayLiteral: 0x02, 0x20, 0x0D, 0x02),
                "the matrix payload names WID 525")
        // The start write: the same, with the value 0.
        #expect(Array(parsed[5].data.prefix(6)) == [UInt8](arrayLiteral: 0x02, 0x00, 0xC0, 0x03, 0x00, 0x00))
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
