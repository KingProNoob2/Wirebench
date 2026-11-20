import Foundation

/// MaraProt v1, the binary protocol the Maramat Duino-S speaks over USB CDC, TCP 5020 and RS-485.
///
/// The framing is deliberately separate from the transport and from the client: the frame has one
/// checksum and one length field, while the USB/serial link and the client state machine are
/// different problems. Reference: `Duino-S_FW/MARAPROT.md`.
public enum MaraProt {
    public static let magic0: UInt8 = 0x4D
    public static let magic1: UInt8 = 0x50
    public static let version1: UInt8 = 0x10
    public static let headerSize = 10
    public static let crcSize = 2
    public static let maxPayloadBytes = 520
    public static let maxFrameBytes = headerSize + maxPayloadBytes + crcSize

    public static let flagResponse: UInt8 = 0x01
    public static let flagError: UInt8 = 0x02

    public enum Opcode: UInt8, Sendable {
        case ping = 0x01
        case getInfo = 0x02
        case vmStatus = 0x10
        case vmControl = 0x11
        case uploadBegin = 0x20
        case uploadChunk = 0x21
        case uploadCommit = 0x22
        case watchSubscribe = 0x30
        case watchPoll = 0x31
        case slotReadBatch = 0x32
        case slotWriteBatch = 0x33
        case rtcGet = 0x40
        case rtcSet = 0x41
        case oneWireScan = 0x50
        case enterRomDfu = 0xF3
    }

    public enum Status: UInt8, Sendable {
        case ok = 0x00
        case crc = 0x01
        case opcode = 0x02
        case parameter = 0x03
        case busy = 0x04
        case state = 0x05
        case storage = 0x06

        public var text: String {
            switch self {
            case .ok: return "OK"
            case .crc: return "CRC or image checksum mismatch"
            case .opcode: return "unsupported opcode"
            case .parameter: return "invalid parameter or payload"
            case .busy: return "device busy"
            case .state: return "invalid VM or upload state"
            case .storage: return "storage write failed"
            }
        }
    }

    public enum TransportKind: UInt8, Sendable {
        case usbCDC = 0
        case tcpIP = 1
        case rs485 = 2
    }

    public enum VMRunState: UInt8, Sendable {
        case stopped = 0
        case running = 1
        case paused = 2
        case fault = 3
        case eStop = 4
    }
}

/// One MaraProt request or response frame.
public struct MaraProtFrame: Equatable, Sendable {
    public var sequence: UInt16
    public var stationId: UInt8
    public var opcode: UInt8
    /// Set on a response when the device rejected the command.
    public var isError: Bool
    public var status: UInt8
    public var payload: [UInt8]
    public var isResponse: Bool

    public init(sequence: UInt16, stationId: UInt8, opcode: UInt8, payload: [UInt8] = [],
                isResponse: Bool = false, isError: Bool = false, status: UInt8 = 0) {
        self.sequence = sequence
        self.stationId = stationId
        self.opcode = opcode
        self.payload = payload
        self.isResponse = isResponse
        self.isError = isError
        self.status = status
    }

    public enum FrameError: Error, Equatable, Sendable {
        case tooShort(Int)
        case badMagic(UInt8, UInt8)
        case badVersion(UInt8)
        case payloadTooLarge(Int)
        case badLength(expected: Int, got: Int)
        case badChecksum(expected: UInt16, got: UInt16)
    }

    /// Encodes a request. Responses are encoded the same way with `isResponse` set; the Duino-S sends
    /// the low flag bits in `verFlags`.
    public func encoded() throws -> [UInt8] {
        guard payload.count <= MaraProt.maxPayloadBytes else {
            throw FrameError.payloadTooLarge(payload.count)
        }
        var flags = MaraProt.version1
        if isResponse { flags |= MaraProt.flagResponse }
        if isError { flags |= MaraProt.flagError }
        var out: [UInt8] = [
            MaraProt.magic0, MaraProt.magic1, flags, stationId,
            UInt8(truncatingIfNeeded: sequence), UInt8(truncatingIfNeeded: sequence >> 8),
            opcode, status,
            UInt8(truncatingIfNeeded: payload.count), UInt8(truncatingIfNeeded: payload.count >> 8),
        ]
        out += payload
        let crc = MaraProtFrame.crc16(out)
        out.append(UInt8(truncatingIfNeeded: crc))
        out.append(UInt8(truncatingIfNeeded: crc >> 8))
        return out
    }

    /// Decodes one complete frame. Extra trailing bytes are ignored so a serial read that picked up two
    /// frames cannot fail the first one.
    public static func decode(_ bytes: [UInt8]) throws -> MaraProtFrame {
        guard bytes.count >= MaraProt.headerSize + MaraProt.crcSize else {
            throw FrameError.tooShort(bytes.count)
        }
        guard bytes[0] == MaraProt.magic0, bytes[1] == MaraProt.magic1 else {
            throw FrameError.badMagic(bytes[0], bytes[1])
        }
        guard bytes[2] & 0xF0 == MaraProt.version1 else {
            throw FrameError.badVersion(bytes[2])
        }
        let payloadLength = Int(bytes[8]) | (Int(bytes[9]) << 8)
        guard payloadLength <= MaraProt.maxPayloadBytes else {
            throw FrameError.payloadTooLarge(payloadLength)
        }
        let expected = MaraProt.headerSize + payloadLength + MaraProt.crcSize
        guard bytes.count >= expected else {
            throw FrameError.badLength(expected: expected, got: bytes.count)
        }
        let covered = Array(bytes[0..<(MaraProt.headerSize + payloadLength)])
        let got = UInt16(bytes[MaraProt.headerSize + payloadLength])
            | (UInt16(bytes[MaraProt.headerSize + payloadLength + 1]) << 8)
        let wanted = MaraProtFrame.crc16(covered)
        guard got == wanted else {
            throw FrameError.badChecksum(expected: wanted, got: got)
        }
        let sequence = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        return MaraProtFrame(
            sequence: sequence,
            stationId: bytes[3],
            opcode: bytes[6],
            payload: Array(bytes[MaraProt.headerSize..<(MaraProt.headerSize + payloadLength)]),
            isResponse: bytes[2] & MaraProt.flagResponse != 0,
            isError: bytes[2] & MaraProt.flagError != 0,
            status: bytes[7]
        )
    }

    /// The length a complete frame starting at `bytes[0]` will have, once the header is present.
    public static func frameLength(from bytes: [UInt8]) -> Int? {
        guard bytes.count >= MaraProt.headerSize else { return nil }
        guard bytes[0] == MaraProt.magic0, bytes[1] == MaraProt.magic1 else { return nil }
        let payloadLength = Int(bytes[8]) | (Int(bytes[9]) << 8)
        guard payloadLength <= MaraProt.maxPayloadBytes else { return nil }
        return MaraProt.headerSize + payloadLength + MaraProt.crcSize
    }

    /// CRC-16-CCITT: polynomial `0x1021`, initial value `0xFFFF`, no final XOR.
    public static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc &<< 1) ^ 0x1021 : (crc &<< 1)
            }
        }
        return crc
    }

    /// Standard IEEE 802.3 CRC-32, as the MFLW image header and upload handshake use.
    public static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
