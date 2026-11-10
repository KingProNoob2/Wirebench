import Foundation

/// DbNet, the protocol the uploader speaks.
///
/// Recovered from `Dirigo_unpacked.exe`; each constant names the address it came from.
///
/// A whole frame is a **15-byte header plus a body of `payload + 6`**:
///
/// ```
/// 0x00  sequence   4
/// 0x04  flag       2
/// 0x06  address    4
/// 0x0A  checksum   4      mix(0x100 + lastPayloadByte + address + sequence, 0)
/// 0x0E  length     1      0 for a 3-byte payload, else the payload length
/// 0x0F  body       L + 6
/// ```
///
/// The body is `[0x10] payload [checksum] [0x16]` when the payload is exactly 3 bytes, and
/// `[0x68][L][L][0x68] payload [checksum] [0x16]` otherwise. So the total is `L + 21`, which is
/// exactly what the receiver insists on (`bytesReceived == length + 0x15`, 0x41BEAC) — the `0x0E`
/// field is 0 for the short form so that 3-byte payloads also come to 21.
public enum DbNetFrame {

    // MARK: - Layout

    /// `TDbNetIpStation.SendReceive` (0x41BDC0) requires `bytesReceived == length + 0x15`.
    public static let overhead = 21

    /// The byte after the payload checksum (`movb $0x16, (%ecx)` at 0x416208).
    public static let terminator: UInt8 = 0x16

    /// A 14-byte frame carrying this flag is not an answer: the master re-sends with an incremented
    /// sequence. `cmpw $0x1111, 0x161(%ebx)` at 0x41BE94, `cmpl $0xe, 0x2cc(%ebx)` at 0x41BE8B.
    public static let retryFlag: UInt16 = 0x1111
    public static let retryFrameLength = 14

    /// The two commands the reply parser accepts: `cmpb $0x10` / `cmpb $0x68` at 0x41E1BB / 0x41E1CC.
    public enum Command: UInt8, Sendable {
        case short = 0x10
        case long = 0x68
    }

    /// Payloads are chunked at 192 bytes: `cmpl $0xc0, %ebx; … movl $0xc0, %ebx` at 0x4334D7.
    public static let maxPayload = 0xC0

    /// Field offsets within a frame, from `sub_0041618C` (0x41618C) and `SendReceive` (0x41BDC0).
    public enum Offset {
        public static let sequence = 0x00
        public static let flag = 0x04
        public static let address = 0x06
        public static let checksum = 0x0A
        public static let length = 0x0E
        public static let payload = 0x0F
    }

    // MARK: - Primitives

    /// The ones'-complement byte sum used by `sub_004161CC` (0x4161CC).
    ///
    /// Note the end-around carry — it is not a plain `& 0xFF` of an ordinary sum, and reproducing
    /// that faithfully is the whole point of writing it out:
    ///
    /// ```
    /// sum += byte
    /// if sum > 0xFF { sum = (sum & 0xFF) + 1 }
    /// ```
    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var sum: UInt16 = 0
        for byte in bytes {
            sum = sum &+ UInt16(byte)
            if sum >= 0x100 {
                sum = (sum & 0xFF) &+ 1
            }
        }
        return UInt8(sum & 0xFF)
    }

    /// The 32-bit scramble behind the `0x0A` checksum field — `sub_00416118` (0x416118).
    ///
    /// Straight from the listing: `ecx` starts as `a` (or 1 when `a` is 0), `ebx = a * b`, then four
    /// rounds of `ecx = ecx*2 + 13; ebx = (ebx + ecx) * b`, returning `a + (ecx + ebx)`.
    public static func mix(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var ecx: UInt32 = a == 0 ? 1 : a
        let edx = b
        var ebx = edx &* ecx
        for _ in 0..<4 {
            ecx = ecx &* 2 &+ 13
            ebx = (ebx &+ ecx) &* edx
        }
        ecx = ecx &+ ebx
        return a &+ ecx
    }

    /// XORs a frame's payload with a key derived from its sequence and address —
    /// `sub_00416144` (0x416144).
    ///
    /// The **first two words use the inverted sequence** (`notl %eax` on `(%edi)` before the first
    /// `call 0x416118`); later words use it as-is. That is why the sequence and address are
    /// cryptographic inputs to the frame, not merely identifiers.
    ///
    /// - Parameter length: the frame's length field, i.e. `0x0E`. The routine covers `length + 6`
    ///   bytes starting at the payload.
    public static func scramble(_ bytes: inout [UInt8], length: UInt8, sequence: UInt32, address: UInt32) {
        var remaining = Int(length) + 6
        var at = Offset.payload
        var key = mix(~sequence, address)
        xorWord(&bytes, at: at, key: key)
        at += 4
        xorWord(&bytes, at: at, key: key)
        at += 4
        remaining -= 8
        while remaining > 0 {
            key = mix(sequence, address)
            xorWord(&bytes, at: at, key: key)
            at += 4
            remaining -= 4
        }
    }

    /// Little-endian dword XOR, as `xorl %eax, (%ebx)` does. Out-of-range words are skipped rather
    /// than writing past the buffer — the original assumes the buffer is big enough.
    private static func xorWord(_ bytes: inout [UInt8], at: Int, key: UInt32) {
        guard at >= 0, at + 4 <= bytes.count else { return }
        let word = UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
            | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        let mixed = word ^ key
        bytes[at] = UInt8(truncatingIfNeeded: mixed)
        bytes[at + 1] = UInt8(truncatingIfNeeded: mixed >> 8)
        bytes[at + 2] = UInt8(truncatingIfNeeded: mixed >> 16)
        bytes[at + 3] = UInt8(truncatingIfNeeded: mixed >> 24)
    }

    // MARK: - Assembling a frame

    /// The body `DbnTransaction` (0x41E114) builds.
    ///
    /// The short form is taken when the payload is **exactly** three bytes (`cmpl $0x3, %ebx; jl` to
    /// reject, `jne` to the long form, 0x41E126 / 0x41E12F), and returns 6 (`movl $0x6, %eax`,
    /// 0x41E15D).
    ///
    /// The long form's four-byte header is `[0x68][length][length][0x68]`, written by
    /// `sub_0041E210` (0x41E21A–0x41E223), and the body comes to `payload + 6`
    /// (`leal 0x6(%ebx), %eax`, 0x41E192).
    ///
    /// In both forms the checksum is taken over the **payload only** — `sub_0041E0D0` (0x41E0D0) is
    /// handed `local+1` with length 3 for the short form, and `local+4` with `L` for the long one —
    /// and the `0x16` terminator is written just after it (`movb $0x16, (%ecx)`, 0x41E10C).
    public static func body(for payload: [UInt8]) -> [UInt8]? {
        let count = payload.count
        guard count >= 3, count <= 255 else { return nil }   // the length is one byte
        var out: [UInt8]
        if count == 3 {
            out = [Command.short.rawValue]
        } else {
            let length = UInt8(count)
            out = [Command.long.rawValue, length, length, Command.long.rawValue]
        }
        out.append(contentsOf: payload)
        out.append(checksum(payload))
        out.append(terminator)
        return out
    }

    /// A complete frame, ready for the transport.
    ///
    /// The `0x0A` field is `mix(0x100 + lastPayloadByte + address + sequence, previous)`, following
    /// `sub_0041618C` (0x41618C) — note that the last payload byte is read **before** the scramble
    /// (0x41619E, ahead of the call at 0x4161A8).
    public static func encode(sequence: UInt32, address: UInt32, payload: [UInt8], flag: UInt16 = 0) -> [UInt8]? {
        guard let body = body(for: payload) else { return nil }
        let lengthField: UInt8 = payload.count == 3 ? 0 : UInt8(payload.count)
        let lastPayloadByte = payload.last ?? 0

        var frame = [UInt8](repeating: 0, count: Offset.payload)
        write32(sequence, into: &frame, at: Offset.sequence)
        write16(flag, into: &frame, at: Offset.flag)
        write32(address, into: &frame, at: Offset.address)
        frame[Offset.length] = lengthField
        frame.append(contentsOf: body)

        scramble(&frame, length: lengthField, sequence: sequence, address: address)

        let seed = UInt32(0x100) &+ UInt32(lastPayloadByte) &+ address &+ sequence
        write32(mix(seed, 0), into: &frame, at: Offset.checksum)
        return frame
    }

    /// Reads back a frame, applying the receiver's own rules so a round trip is a real check:
    /// the total must be `length + overhead` and the command must be one of the two.
    public struct Decoded: Equatable, Sendable {
        public var sequence: UInt32
        public var flag: UInt16
        public var address: UInt32
        public var payload: [UInt8]
    }

    /// Why a frame was rejected. Each case is one of the receiver's own checks, so a failure names
    /// the rule that caught it rather than just returning nil.
    public enum ParseFailure: Error, Equatable {
        /// Shorter than a header plus the smallest body.
        case tooShort
        /// The receiver insists on `bytesReceived == length + 0x15` (0x41BEAC).
        case lengthMismatch(expected: Int, got: Int)
        /// Only `0x10` and `0x68` are accepted (0x41E1BB / 0x41E1CC).
        case unknownCommand(UInt8)
        /// The body is not the shape its command implies.
        case badBodyLength
        /// `sub_0041E0D0` (0x41E0D0) sums the payload and compares.
        case badChecksum
        /// The `0x16` terminator must follow the checksum byte (`movb $0x16, (%ecx)`, 0x41E10C).
        case badTerminator
    }

    /// The frame's flag field at `0x04`, as `SendReceive` compares it (`cmpw $0x1111`, 0x41BE94).
    public static func flag(of frame: [UInt8]) -> UInt16 {
        read16(frame, at: Offset.flag)
    }

    public static func parse(_ frame: [UInt8]) -> Result<Decoded, ParseFailure> {
        guard frame.count >= Offset.payload + 6 else { return .failure(.tooShort) }
        let lengthField = frame[Offset.length]
        let expected = Int(lengthField) + overhead
        guard frame.count == expected else {
            return .failure(.lengthMismatch(expected: expected, got: frame.count))
        }

        let sequence = read32(frame, at: Offset.sequence)
        let address = read32(frame, at: Offset.address)
        // Undo the scramble before reading anything out of the body: XOR is its own inverse, and the
        // same key derivation applies.
        var whole = frame
        scramble(&whole, length: lengthField, sequence: sequence, address: address)
        let body = Array(whole[Offset.payload...])

        guard let command = Command(rawValue: body[0]) else {
            return .failure(.unknownCommand(body[0]))
        }
        let payload: [UInt8]
        switch command {
        case .short:
            // [0x10][3 bytes][checksum][0x16]
            guard body.count == 6 else { return .failure(.badBodyLength) }
            payload = Array(body[1..<4])
        case .long:
            // [0x68][L][L][0x68][payload][checksum][0x16]
            let count = Int(body[1])
            guard count > 3, body.count == count + 6 else { return .failure(.badBodyLength) }
            payload = Array(body[4..<(4 + count)])
        }
        let checksumAt = command == .short ? 4 : payload.count + 4
        guard checksum(payload) == body[checksumAt] else { return .failure(.badChecksum) }
        guard body[checksumAt + 1] == terminator else { return .failure(.badTerminator) }

        return .success(Decoded(sequence: sequence, flag: read16(frame, at: Offset.flag),
                                address: address, payload: payload))
    }

    // MARK: - Little-endian field access

    private static func write32(_ value: UInt32, into bytes: inout [UInt8], at index: Int) {
        guard index + 4 <= bytes.count else { return }
        for i in 0..<4 { bytes[index + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    private static func write16(_ value: UInt16, into bytes: inout [UInt8], at index: Int) {
        guard index + 2 <= bytes.count else { return }
        for i in 0..<2 { bytes[index + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    private static func read32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        guard index + 4 <= bytes.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[index + $1]) << (8 * $1)) }
    }

    private static func read16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        guard index + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    // MARK: - Reading a reply

    /// The body length a reply must satisfy, and the length/command it carries.
    ///
    /// From `SendReceive`: `0x16B` is the length, `0x16C` the command; the receiver insists on
    /// `bytesReceived == length + 0x15` (0x41BEAC) and on the command being `0x10` or `0x68`
    /// (0x41BEF6).
    public struct Reply: Equatable, Sendable {
        public var command: Command
        /// The payload, starting just after the command byte.
        public var payload: [UInt8]
    }

    /// Reads a reply body — the part the transaction parses — out of a received frame.
    ///
    /// `TBaseDbnMaster.DbnTransaction` (0x41E114) reads the first byte: `0x10` means a 3-byte body
    /// with data at +1, `0x68` means the count is at +1 and data at +4. Anything else is a failure.
    public static func reply(from body: [UInt8]) -> Reply? {
        guard let first = body.first, let command = Command(rawValue: first) else { return nil }
        switch command {
        case .short:
            guard body.count >= 3 else { return nil }
            return Reply(command: .short, payload: Array(body[1..<3]))
        case .long:
            guard body.count >= 4 else { return nil }
            let count = Int(body[1])
            guard body.count >= 4 + count else { return nil }
            return Reply(command: .long, payload: Array(body[4..<(4 + count)]))
        }
    }
}

// MARK: - The serial frame, verified against captured traffic

extension DbNetFrame {
    /// A frame as it appears on the RS485 link.
    ///
    /// Verified against a captured upload (`message.txt`, 24 frames). There is **no 15-byte header, no
    /// sequence field and no payload scramble** on this transport — that framing belongs to
    /// `TDbNetIpStation`, the UDP station, which is what the early rounds read.
    ///
    /// ```
    /// short:  10 DA SA FCB CS 16
    /// long:   68 L L 68 DA SA FCB <data...> CS 16      L = 3 + len(data)
    /// ```
    ///
    /// `DA` and `SA` are the destination and source addresses — `PLC Address 1` and `PC Address 31`
    /// from the *Unit config* dialog — and `FCB` is the function byte. The checksum is the
    /// ones'-complement sum over the `L` bytes, i.e. from `DA` onward; the captured frames confirm it
    /// on every message, including the 143-byte matrix write.
    public struct SerialFrame: Equatable, Sendable {
        public var destination: UInt8
        public var source: UInt8
        public var function: UInt8
        /// Empty for the short form.
        public var data: [UInt8]

        public init(destination: UInt8, source: UInt8, function: UInt8, data: [UInt8] = []) {
            self.destination = destination
            self.source = source
            self.function = function
            self.data = data
        }
    }

    /// The function bytes seen on the wire.
    public enum Function: UInt8, Sendable {
        case getStatus = 0x49
        case write = 0x45
        case read = 0x4D
        case readReply = 0x08
    }

    public enum SerialError: Error, Equatable {
        case tooShort
        case badMarker(UInt8)
        case badLength(expected: Int, got: Int)
        case badChecksum(expected: UInt8, got: UInt8)
        case badTerminator(UInt8)
    }

    /// Encodes a frame for the serial link. The short form is used when there is no data.
    public static func encodeSerial(destination: UInt8, source: UInt8,
                                    function: UInt8, data: [UInt8] = []) -> [UInt8] {
        let payload = [destination, source, function] + data
        var out: [UInt8]
        if data.isEmpty {
            out = [Command.short.rawValue] + payload
        } else {
            let length = UInt8(truncatingIfNeeded: payload.count)
            out = [Command.long.rawValue, length, length, Command.long.rawValue] + payload
        }
        out.append(checksum(payload))
        out.append(terminator)
        return out
    }

    /// Decodes a frame from the serial link, applying the same checks the captured traffic satisfies.
    public static func parseSerial(_ bytes: [UInt8]) -> Result<SerialFrame, SerialError> {
        guard let marker = bytes.first else { return .failure(.tooShort) }
        switch Command(rawValue: marker) {
        case .short:
            // 10 DA SA FCB CS 16
            guard bytes.count >= 6 else { return .failure(.tooShort) }
            guard bytes.count == 6 else { return .failure(.badLength(expected: 6, got: bytes.count)) }
            let payload = Array(bytes[1..<4])
            guard checksum(payload) == bytes[4] else {
                return .failure(.badChecksum(expected: checksum(payload), got: bytes[4]))
            }
            guard bytes[5] == terminator else { return .failure(.badTerminator(bytes[5])) }
            return .success(SerialFrame(destination: payload[0], source: payload[1],
                                        function: payload[2], data: []))
        case .long:
            // 68 L L 68 DA SA FCB <data...> CS 16
            guard bytes.count >= 8 else { return .failure(.tooShort) }
            let length = Int(bytes[1])
            guard bytes[2] == bytes[1], bytes[3] == Command.long.rawValue else {
                return .failure(.badLength(expected: Int(bytes[1]) + 6, got: bytes.count))
            }
            guard bytes.count == length + 6 else {
                return .failure(.badLength(expected: length + 6, got: bytes.count))
            }
            let payload = Array(bytes[4..<(4 + length)])
            guard payload.count >= 3 else { return .failure(.tooShort) }
            guard checksum(payload) == bytes[4 + length] else {
                return .failure(.badChecksum(expected: checksum(payload), got: bytes[4 + length]))
            }
            guard bytes[5 + length] == terminator else {
                return .failure(.badTerminator(bytes[5 + length]))
            }
            return .success(SerialFrame(destination: payload[0], source: payload[1],
                                        function: payload[2], data: Array(payload[3...])))
        case nil:
            return .failure(.badMarker(marker))
        }
    }
}
