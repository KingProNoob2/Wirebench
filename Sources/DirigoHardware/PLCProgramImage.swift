import Foundation
import Compression

/// A Dirigo **Program Binary** (`.pbd`) — what Dirigo's *File → Export → Program Binary…* writes, and
/// what the uploader sends to the PLC.
///
/// Recovered from two artefacts rather than from reading alone: `ExportFileProgramBinary` (0x4B26E0)
/// shows the file is wrapped in a `TZCompressionStream`, and a real export (`had.pbd`, exported from
/// `had.pcc`) shows the layout inside it:
///
/// ```
/// 0x0000  a 256-byte header, with the project's file name as a short string at +0x10
/// 0x0100  block: id 0x20D (525), length 0x108 (264)   -> 8 bytes + 256 bytes of section data
/// 0x0210  block: id 0x21C (540), length 8              -> 8 bytes
/// ```
///
/// **The length excludes the eight-byte `[id][length]` prefix.** That was the one detail that took
/// the byte arithmetic to settle: `256 + (8 + 264) + (8 + 8) = 544`, which is exactly the size the
/// real file decompresses to.
public struct PLCProgramImage: Equatable, Sendable {
    /// The file's header, verbatim. 256 bytes in the one real export available.
    public var header: [UInt8]
    /// The project's file name, from the short string at `header[0x10]`.
    public var projectName: String
    /// The sections, in file order.
    public var blocks: [Block]

    public static let headerSize = 256
    public static let nameOffset = 0x10

    public struct Block: Equatable, Sendable {
        /// Section id. `0x20D` (525) and `0x21C` (540) are the two `ExportFileProgramBinary`
        /// immediates; the value arrays use 500, 501, 502 and the uploader's thread sections
        /// 520 + n.
        public var id: UInt32
        public var payload: [UInt8]

        public init(id: UInt32, payload: [UInt8]) {
            self.id = id
            self.payload = payload
        }
    }

    public enum ParseError: Error, Equatable {
        case tooShort
        case badName
        case truncatedBlock(id: UInt32, needed: Int, got: Int)
    }

    // MARK: - Parsing the decompressed bytes

    public static func parse(_ bytes: [UInt8]) throws -> PLCProgramImage {
        guard bytes.count >= headerSize else { throw ParseError.tooShort }
        let header = Array(bytes[0..<headerSize])

        // The name is a short string: a length byte then that many bytes.
        let nameLength = Int(bytes[nameOffset])
        guard nameOffset + 1 + nameLength <= headerSize else { throw ParseError.badName }
        let nameBytes = bytes[(nameOffset + 1)..<(nameOffset + 1 + nameLength)]
        let name = String(decoding: nameBytes, as: UTF8.self)

        var blocks: [Block] = []
        var cursor = headerSize
        while cursor + 8 <= bytes.count {
            let id = readU32(bytes, at: cursor)
            let length = Int(readU32(bytes, at: cursor + 4))
            let start = cursor + 8
            guard start + length <= bytes.count else {
                throw ParseError.truncatedBlock(id: id, needed: length, got: bytes.count - start)
            }
            blocks.append(Block(id: id, payload: Array(bytes[start..<(start + length)])))
            cursor = start + length
        }
        return PLCProgramImage(header: header, projectName: name, blocks: blocks)
    }

    /// The image as it sits inside the compressed file.
    public func serialized() -> [UInt8] {
        var out = header
        if out.count < Self.headerSize {
            out.append(contentsOf: repeatElement(0, count: Self.headerSize - out.count))
        }
        for block in blocks {
            out.append(contentsOf: withU32(block.id))
            out.append(contentsOf: withU32(UInt32(block.payload.count)))
            out.append(contentsOf: block.payload)
        }
        return out
    }

    private static func readU32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[index + $1]) << (8 * $1)) }
    }

    private func withU32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    // MARK: - The zlib wrapper

    /// Inflates a `.pbd` file: a zlib stream, which is a two-byte header, raw DEFLATE, and a
    /// four-byte Adler-32.
    ///
    /// `COMPRESSION_ZLIB` in Apple's Compression framework means *raw* DEFLATE, so the zlib framing is
    /// stripped here rather than handed over — the header is what identifies the format (a real export
    /// starts `78 9C`), and the checksum is not used.
    public static func inflate(_ file: [UInt8]) throws -> [UInt8] {
        guard file.count > 6 else { throw ParseError.tooShort }
        guard file[0] & 0x0F == 8 else { throw ParseError.tooShort }   // CM = deflate
        let body = Array(file[2..<(file.count - 4)])

        var capacity = max(body.count * 8, 4096)
        while capacity <= 1 << 24 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = body.withUnsafeBufferPointer { input in
                out.withUnsafeMutableBufferPointer { output in
                    compression_decode_buffer(output.baseAddress!, capacity,
                                              input.baseAddress!, input.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return Array(out[0..<written]) }
            capacity *= 4
        }
        throw ParseError.tooShort
    }

    /// Reads a `.pbd` file straight through.
    public static func load(contentsOf url: URL) throws -> PLCProgramImage {
        try parse(try inflate([UInt8](try Data(contentsOf: url))))
    }

    // MARK: - Writing one

    /// The section ids a program-binary export carries here: the program table and its trailer.
    public static let programTableSection: UInt32 = 525
    public static let trailerSection: UInt32 = 540

    /// The eight bytes the table's section is prefixed with, from the one real export.
    public static let tableSectionHeader: [UInt8] = [0, 0, 0, 0, 0x80, 0, 0, 0]
    /// And the trailer section's eight bytes, likewise.
    public static let trailerPayload: [UInt8] = [0x10, 0, 0, 0, 0x08, 0, 0, 0]

    /// A header for a project that has no imported one.
    ///
    /// The four leading words are the ones `had.pbd` carries — this app has exactly one real export to
    /// learn them from, and only the table's section is read back by the uploader — then the project's
    /// name as the short string at `+0x10`. A build report says when this was used, so a header that
    /// matters can come from a `.pbd` Dirigo wrote.
    public static func defaultHeader(projectName: String) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: headerSize)
        let words: [UInt8] = [0, 0, 0, 0, 0xF8, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0]
        for (i, b) in words.enumerated() { header[i] = b }
        let name = Array(projectName.utf8.prefix(255))
        header[nameOffset] = UInt8(name.count)
        for (i, b) in name.enumerated() { header[nameOffset + 1 + i] = b }
        return header
    }

    /// Wraps a compiled program table as the `.pbd` Dirigo's *Program Binary* export writes:
    /// a header, the table's section, and the trailer — zlib-framed.
    ///
    /// The table is variable length. The eight-byte sub-header is the constant `had.pbd` carries, which is
    /// known only for a 256-byte table; a `.pbd` for another size is written with the same sub-header and
    /// is not verified against a Dirigo export.
    public static func programBinary(table: [UInt8], projectName: String,
                                     header: [UInt8]? = nil) throws -> [UInt8] {
        guard table.count >= PLCProgramTable.bodyOffset + PLCProgramTable.trailerLength else {
            throw ParseError.tooShort
        }
        let head = header ?? defaultHeader(projectName: projectName)
        guard head.count == headerSize else { throw ParseError.tooShort }
        var image = PLCProgramImage(header: head, projectName: projectName, blocks: [
            Block(id: programTableSection, payload: tableSectionHeader + table),
            Block(id: trailerSection, payload: trailerPayload),
        ])
        image.header = head
        return try image.deflated()
    }

    /// The zlib stream `inflate` reads: a two-byte header, raw DEFLATE, and Adler-32.
    public func deflated() throws -> [UInt8] {
        let raw = serialized()
        var capacity = max(raw.count + 64, 256)
        while capacity <= 1 << 24 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = raw.withUnsafeBufferPointer { input in
                out.withUnsafeMutableBufferPointer { output in
                    compression_encode_buffer(output.baseAddress!, capacity,
                                              input.baseAddress!, input.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                let body = Array(out[0..<written])
                // 0x78 0x9C is the zlib header for default compression, which is what a real export
                // starts with. The trailer is the Adler-32 of the *uncompressed* bytes, and zlib writes
                // it **big-endian** — unlike every integer inside the image itself. Writing it with the
                // image's own little-endian helper produced a stream `zlib.decompress` rejected with
                // "incorrect data check", while Apple's `compression_decode_buffer` accepted it because
                // it ignores the trailer.
                let sum = Self.adler32(raw)
                return [0x78, 0x9C] + body + [UInt8(truncatingIfNeeded: sum >> 24),
                                              UInt8(truncatingIfNeeded: sum >> 16),
                                              UInt8(truncatingIfNeeded: sum >> 8),
                                              UInt8(truncatingIfNeeded: sum)]
            }
            capacity *= 4
        }
        throw ParseError.tooShort
    }

    /// Adler-32, as zlib frames it: two running sums modulo 65521, high half first.
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
