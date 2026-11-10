import Foundation
#if canImport(Compression)
import Compression
#else
import CZlib
#endif

/// Raw DEFLATE (no zlib header or checksum), the one primitive `PLCProgramImage` needs from a compressor.
///
/// Apple's Compression framework has it as `COMPRESSION_ZLIB`; elsewhere zlib does, with a negative window size.
/// Both take the buffer to write into and say `nil` when it is too small, so the callers grow it and try again.
enum RawDeflate {
    static func decode(_ input: [UInt8], capacity: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: capacity)
        #if canImport(Compression)
        let written = input.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, capacity, source.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        #else
        let written = run(input, into: &out, initialise: { inflateInit2_($0, -15, ZLIB_VERSION, streamSize) },
                          step: { inflate($0, Z_FINISH) }, finish: { inflateEnd($0) })
        #endif
        return written > 0 ? Array(out[0..<written]) : nil
    }

    static func encode(_ input: [UInt8], capacity: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: capacity)
        #if canImport(Compression)
        let written = input.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                compression_encode_buffer(target.baseAddress!, capacity, source.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        #else
        let written = run(input, into: &out,
                          initialise: { deflateInit2_($0, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                                                      Z_DEFAULT_STRATEGY, ZLIB_VERSION, streamSize) },
                          step: { deflate($0, Z_FINISH) }, finish: { deflateEnd($0) })
        #endif
        return written > 0 ? Array(out[0..<written]) : nil
    }

    #if !canImport(Compression)
    private static let streamSize = Int32(MemoryLayout<z_stream>.size)

    /// One zlib call over the whole input: the bytes written, or 0 when the stream did not end inside `out`.
    private static func run(_ input: [UInt8], into out: inout [UInt8],
                            initialise: (UnsafeMutablePointer<z_stream>) -> Int32,
                            step: (UnsafeMutablePointer<z_stream>) -> Int32,
                            finish: (UnsafeMutablePointer<z_stream>) -> Int32) -> Int {
        var stream = z_stream()
        guard initialise(&stream) == Z_OK else { return 0 }
        defer { _ = finish(&stream) }
        var input = input
        let capacity = out.count
        return input.withUnsafeMutableBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress
                stream.avail_in = UInt32(source.count)
                stream.next_out = target.baseAddress
                stream.avail_out = UInt32(capacity)
                return step(&stream) == Z_STREAM_END ? Int(stream.total_out) : 0
            }
        }
    }
    #endif
}
