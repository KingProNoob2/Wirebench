import Foundation

/// The program table — the 525 section the uploader sends.
///
/// Recovered from `TPCCProject.Compile` (the 64-byte definition record), from controlled export diffs
/// (`had.dmp` vs `had+1block.dmp`), and from captured uploads (`message.txt`, and
/// `Serial packet capture/message.txt`, a 640-byte upload of a larger project).
///
/// The table is **variable length**. Its size follows the module records it holds:
///
/// ```
/// 0x00  header, 64 bytes
///         +0x02  version = 1
///         +0x04  a project flag
///         +0x06, +0x07  two more project flags
///         +0x1C  checksum (16-bit, little-endian), CRC-16 — see the extension below
/// 0x40  per-module records, back to back, as many bytes as the modules need
/// S     0xFFFF sentinel, where S = 0x40 + records + 0x22   (34 zero bytes sit before it)
/// S+12  0xD0 0x00 0xD0 0x00 — a constant, not the table length
/// S+16  the profile name, space-padded to 32 bytes
/// S+48  12 zero bytes; the table ends at S+60
/// ```
///
/// Every trailer field is measured from the sentinel, so the trailer is the same 60 bytes whatever the
/// size of the records. The upload sends the whole table: the captured 192-byte table of one project,
/// the 640-byte table of another, and the 256-byte `had.dmp` all follow `length = S + 60`.
public struct PLCProgramTable: Equatable, Sendable {
    public static let headerSize = 0x40
    public static let versionOffset = 0x02
    public static let checksumOffset = 0x1C
    public static let bodyOffset = 0x40
    /// The records are padded to a 64-byte boundary of the table (`TPCCProject.Compile` pads the stream with
    /// `-size & 0x3F` zeros, 0x4B01E0), and a last 64-byte block of four zero bytes and the 60-byte trailer
    /// follows. So the sentinel sits at the boundary plus four and the whole table is a multiple of 64. The
    /// captures fix it: 482 record bytes → `0x244` (640 bytes), 486 → `0x244` (the `-mod2` save), `had.dmp`'s
    /// 98 → `0xC4` (256), and the 192-byte table's `0x84`.
    public static let sentinelAlignment = 0x40
    public static let sentinelPad = 4
    /// The words of the header's thread table: thread `t` (1-based) at `0x20 + 2 (t - 1)`.
    public static let threadTableOffset = 0x20
    public static let maxThreads = 16
    /// The sentinel's offset for a table whose records take `records` bytes.
    public static func sentinelOffset(records: Int) -> Int {
        let end = bodyOffset + records
        return (end + sentinelAlignment - 1) / sentinelAlignment * sentinelAlignment + sentinelPad
    }
    /// Bytes from the sentinel to the end of the table.
    public static let trailerLength = 60
    public static let profileLength = 32

    /// The whole table, verbatim. The header and trailer fields below are *views* onto this, so a
    /// re-emit is byte-identical by construction and the parts that are not yet decoded are preserved
    /// rather than silently dropped.
    public var bytes: [UInt8]

    public enum ParseError: Error, Equatable {
        case tooShort(Int)
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.bodyOffset + Self.trailerLength else {
            throw ParseError.tooShort(bytes.count)
        }
        self.bytes = bytes
    }

    /// The length of a table whose records take `records` bytes.
    public static func length(records: Int) -> Int {
        sentinelOffset(records: records) + trailerLength
    }

    /// A table built from `records`: the header and trailer of `template`, the records between them,
    /// the gap, and the checksum recomputed. Its length follows the records.
    ///
    /// The header words that follow from the layout are written here, as `TPCCProject.Compile` does
    /// (0x4B0E3A and 0x4B0F20): `+0x10` is the end of the padded records in 16-byte units, `+0x1A` the table
    /// length in 64-byte units, and the thread table at `+0x20` holds, for each thread that produced
    /// records, the offset of its first record in 16-byte units (`threadStarts` maps a thread id to its
    /// offset in `records`; a thread without records is 0). The project flags at `+0x04…+0x07` and anything
    /// else in the header come from the template.
    public static func assemble(template: PLCProgramTable, records: [UInt8],
                                threadStarts: [Int: Int] = [:]) -> [UInt8] {
        var out = Array(template.bytes[0..<bodyOffset])
        let sentinel = sentinelOffset(records: records.count)
        let total = sentinel + trailerLength
        func put(_ value: Int, at offset: Int) {
            out[offset] = UInt8(truncatingIfNeeded: value)
            out[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        put((sentinel - sentinelPad) / 16, at: 0x10)
        put(total / 64, at: 0x1A)
        // With no thread information the template's table is kept.
        if !threadStarts.isEmpty {
            for slot in 0..<maxThreads { put(0, at: threadTableOffset + 2 * slot) }
            for (thread, start) in threadStarts where thread >= 1 && thread <= maxThreads {
                put((bodyOffset + start) / 16, at: threadTableOffset + 2 * (thread - 1))
            }
        }
        out += records
        out += [UInt8](repeating: 0, count: sentinel - out.count)
        out += template.bytes[template.sentinelOffset...]
        out[checksumOffset] = 0
        out[checksumOffset + 1] = 0
        let sum = computeChecksum(out)
        out[checksumOffset] = UInt8(truncatingIfNeeded: sum)
        out[checksumOffset + 1] = UInt8(truncatingIfNeeded: sum >> 8)
        return out
    }

    // MARK: - Trailer, measured from the sentinel

    /// The `0xFFFF` sentinel that ends the module records.
    public var sentinelOffset: Int { bytes.count - Self.trailerLength }

    /// The constant `0xD0 0x00 0xD0 0x00` that opens the trailer's name block.
    public var lengthOffset: Int { sentinelOffset + 12 }

    /// The profile name, space-padded to `profileLength` bytes.
    public var profileOffset: Int { sentinelOffset + 16 }

    // MARK: - The fields that are established

    /// The format version, `1` in every real table seen (`movw $0x1`, 0x4B0A07).
    public var version: UInt16 { read16(Self.versionOffset) }

    /// The three project flags at `+0x04`, `+0x06` and `+0x07`. Their source was traced to project
    /// fields 0x9E, 0x9C and 0x9D; what those fields *mean* is not established.
    public var projectFlags: (UInt8, UInt8, UInt8) {
        (bytes[0x04], bytes[0x06], bytes[0x07])
    }

    /// The 16-bit checksum at `+0x1C`.
    public var checksum: UInt16 { read16(Self.checksumOffset) }

    /// The `0xFFFF` sentinel word.
    public var sentinel: UInt16 { read16(sentinelOffset) }

    /// The constant that opens the name block, recorded twice. It is `0xD0` in every table seen, at
    /// every size, so it is a constant of the format and not the table length.
    public var nameBlockConstant: (UInt16, UInt16) { (read16(lengthOffset), read16(lengthOffset + 2)) }

    /// The profile name, space-padded to 32 bytes — `"Sybas Control P3"` in every table seen, which is
    /// the platform the projects select with `PROFILE="Sybas P3"`.
    public var profileName: String {
        let slice = bytes[profileOffset..<(profileOffset + Self.profileLength)]
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// The module records' bytes, between the header and the sentinel's gap.
    public var moduleTable: [UInt8] { Array(bytes[Self.bodyOffset..<sentinelOffset]) }

    /// The bytes that are uploaded: the whole table. Every capture sends all of it.
    public var uploadedBytes: [UInt8] { bytes }

    /// The payload `sub_00431F30` builds for one matrix frame.
    ///
    /// From the captured traffic and the helper's own arithmetic at 0x432110:
    ///
    /// ```
    /// [2][0x20][WID: 525][Col][Row][NCols][NRows][data]
    /// ```
    ///
    /// `Col` is the byte offset **divided by** the row stride — `idivl 0x20(%ebp)` at 0x432118, where
    /// the divisor is `NRows x 2` — so the mapping is linear: with `NRows = 8` a column is 16 bytes, and
    /// `Col = 8` is byte 128. `NCols` is how many columns this frame carries.
    public func matrixWritePayload(byteOffset: Int, columns: UInt16, rows: UInt16 = 8,
                                   data: [UInt8]) -> [UInt8] {
        let stride = Int(rows) * 2
        let col = stride > 0 ? byteOffset / stride : 0
        var out: [UInt8] = [0x02, 0x20]
        out.append(contentsOf: [0x0D, 0x02])              // WID 525, little-endian
        out.append(contentsOf: with16(UInt16(col)))       // Col
        out.append(contentsOf: with16(0))                 // Row
        out.append(contentsOf: with16(columns))           // NCols
        out.append(contentsOf: with16(rows))              // NRows
        out.append(contentsOf: data)
        return out
    }

    /// The whole table as the sequence of matrix payloads the uploader sends.
    ///
    /// The table is split into chunks of `chunkBytes`, each of whole columns of `rows` 16-bit values.
    /// The captures use 128 bytes (eight columns) and send the remainder as its own frame: 640 bytes is
    /// five frames, 192 is two (128 and 64).
    public func matrixWriteFrames(rows: UInt16 = 8, chunkBytes: Int = 128) -> [[UInt8]] {
        let body = uploadedBytes
        let stride = Int(rows) * 2
        var frames: [[UInt8]] = []
        var offset = 0
        while offset < body.count {
            let take = min(chunkBytes, body.count - offset)
            let columns = UInt16((take + stride - 1) / stride)
            frames.append(matrixWritePayload(byteOffset: offset, columns: columns, rows: rows,
                                             data: Array(body[offset..<(offset + take)])))
            offset += take
        }
        return frames
    }

    private func read16(_ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func with16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}

// MARK: - The checksum

extension PLCProgramTable {
    /// The table's `0x1C` field: a reflected CRC-16 with polynomial `0xA001` — CRC-16/ARC's, reflected
    /// — seeded `0xFFFF`, taken over the whole table with this field read as zero, then inverted.
    ///
    /// The inversion is the `notw %ax` at 0x4B0F4B; the seed is `movw $0xFFFF, %ax` at 0x4B0F2C.
    ///
    /// Checked against three real tables: `had.dmp` (256 bytes), the 192-byte upload in
    /// `message.txt`, and the 640-byte upload in `Serial packet capture/message.txt`. All three match.
    public static func computeChecksum(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return ~crc
    }

    /// The field as this table's own bytes should carry it.
    public var computedChecksum: UInt16 {
        var copy = bytes
        copy[Self.checksumOffset] = 0
        copy[Self.checksumOffset + 1] = 0
        return Self.computeChecksum(copy)
    }

    /// True when the stored field is the one these bytes produce.
    public var checksumIsValid: Bool { checksum == computedChecksum }
}
