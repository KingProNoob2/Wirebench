import Foundation

/// The 256-byte program table — the 525 section the uploader sends.
///
/// Recovered from `TPCCProject.Compile` (the 64-byte definition record), from a controlled export
/// diff (`had.dmp` vs `had+1block.dmp`, which showed one 16-bit address per pin), and from a captured
/// upload (`message.txt`, which shows the table's bytes travelling inside the `WriteVariable` matrix
/// frames for WID 525).
///
/// The layout, as far as it is established:
///
/// ```
/// 0x00  header, 64 bytes
///         +0x02  version = 1
///         +0x04  a project flag
///         +0x06, +0x07  two more project flags
///         +0x1C  checksum (16-bit, little-endian)
/// 0x40  per-module entries: a small header then one 16-bit address per pin
/// 0xC4  0xFFFF sentinel
/// 0xD0  the data length, twice
/// 0xD4  the profile name, space-padded to 32 bytes
/// ```
///
/// **The checksum is not computable here.** `sub_004AFBA4` is called twice — over the 64-byte record,
/// then over a stream the compiler holds — and no standard CRC-16 over anything present in the exports
/// reproduces it (see the protocol document; the search covered fourteen variants across seven ranges,
/// plus the two-stage form). So the field is carried verbatim: parsing and re-emitting a real table is
/// byte-identical, and generating a *new* one needs that algorithm.
public struct PLCProgramTable: Equatable, Sendable {
    public static let size = 256
    public static let headerSize = 0x40
    public static let versionOffset = 0x02
    public static let checksumOffset = 0x1C
    public static let bodyOffset = 0x40
    public static let sentinelOffset = 0xC4
    public static let lengthOffset = 0xD0
    public static let profileOffset = 0xD4
    public static let profileLength = 32

    /// The whole table, verbatim. The header and trailer fields below are *views* onto this, so a
    /// re-emit is byte-identical by construction and the parts that are not yet decoded are preserved
    /// rather than silently dropped.
    public var bytes: [UInt8]

    public enum ParseError: Error, Equatable {
        case wrongSize(Int)
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.size else { throw ParseError.wrongSize(bytes.count) }
        self.bytes = bytes
    }

    // MARK: - The fields that are established

    /// The format version, `1` in every real table seen (`movw $0x1`, 0x4B0A07).
    public var version: UInt16 { read16(Self.versionOffset) }

    /// The three project flags at `+0x04`, `+0x06` and `+0x07`. Their source was traced to project
    /// fields 0x9E, 0x9C and 0x9D; what those fields *mean* is not established.
    public var projectFlags: (UInt8, UInt8, UInt8) {
        (bytes[0x04], bytes[0x06], bytes[0x07])
    }

    /// The 16-bit checksum at `+0x1C`, carried verbatim.
    public var checksum: UInt16 { read16(Self.checksumOffset) }

    /// The `0xFFFF` sentinel that ends the module table (`movw $0xffff, %ax` feeding the record's tail).
    public var sentinel: UInt16 { read16(Self.sentinelOffset) }

    /// The data length, recorded twice at `0xD0`, which equals `0xD0` in the real table.
    public var dataLength: (UInt16, UInt16) { (read16(Self.lengthOffset), read16(Self.lengthOffset + 2)) }

    /// The profile name at `0xD4`, space-padded to 32 bytes — `"Sybas Control P3"` in the real table,
    /// which is the platform the projects select with `PROFILE="Sybas P3"`.
    public var profileName: String {
        let slice = bytes[Self.profileOffset..<(Self.profileOffset + Self.profileLength)]
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// The module table's bytes, verbatim, between the header and the sentinel.
    public var moduleTable: [UInt8] { Array(bytes[Self.bodyOffset..<Self.sentinelOffset]) }

    /// The table's real length: the `0xD0` field records it (`0xD0` = 208 in the real export, which
    /// is why a 256-byte file is a padded one).
    public var realLength: Int {
        let recorded = Int(dataLength.0)
        return recorded > 0 && recorded <= bytes.count ? recorded : bytes.count
    }

    /// The table's bytes as they are actually uploaded — `realLength` of them, not the padding.
    public var uploadedBytes: [UInt8] { Array(bytes.prefix(realLength)) }

    /// The payload `sub_00431F30` builds for one matrix frame.
    ///
    /// From the captured traffic and the helper's own arithmetic at 0x432110:
    ///
    /// ```
    /// [2][0x20][WID: 525][Col][Row][NCols][NRows][data]
    /// ```
    ///
    /// `Col` is the byte offset **divided by** the row stride — `idivl 0x20(%ebp)` at 0x432118, where
    /// the divisor is `NRows x 2` — so the mapping is linear: with the captured `NRows = 8` a column is
    /// 16 bytes, and the capture's second frame at `Col = 8` is byte 128. `NCols` is how many columns
    /// this frame carries.
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
    /// The grant is split into columns of `rows` 16-bit values, and sent in chunks of `chunkBytes`
    /// (the uploader clamps `compilation[0x70]` into 64…240, and the captured upload used 128 — eight
    /// columns — then a 64-byte remainder, exactly as splitting 192 bytes that way gives).
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
    /// **How this was found.** Three rounds of testing named CRC-16 variants and the ones'-complement
    /// sum from the user's files matched nothing. Searching **every** reflected polynomial against two
    /// real exports, with the field zeroed, produced exactly one candidate — this one — matching both
    /// files. A single survivor across 65 536 candidates and two independent datasets is as close to
    /// proof as this exercise gets.
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
