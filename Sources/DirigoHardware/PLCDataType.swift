import Foundation

/// The PLC's pin data types.
///
/// Recovered from `PccBase.bpl`:
///
/// * the names come from `PinDataTypeToStr` (`0x47D430`), which indexes a string-pointer table at
///   `0x485490`;
/// * the single-character `TYPE` codes come from `CharToPinDataType` (`0x47D44C`), which compares the
///   first wide character against a 12-entry `uint16` table at `0x485478`;
/// * the sizes come from `GetDataSize` (`0x47E4E8`), a jump table on `type & 0x7F` — bit 7 is a flag.
///
/// The codes are not a guess: `<IN_PIN TYPE="1" …>` appears 173 times and `<OUT_PIN TYPE="I" …>`
/// 4 times across the projects on this machine, and no project uses a code outside this table.
public enum PLCDataType: UInt8, CaseIterable, Sendable {
    case boolean = 0
    case shortint = 1
    case smallint = 2
    case longint = 3
    case int64 = 4
    case byte = 5
    case word = 6
    case longword = 7
    case single = 8
    case double = 9
    case extended = 10

    /// The character `.pcc` files carry in a pin's `TYPE` attribute (`CharToPinDataType`, 0x485478).
    public var code: Character {
        switch self {
        case .boolean:  return "1"
        case .shortint: return "8"
        case .smallint: return "I"
        case .longint:  return "L"
        case .int64:    return "6"
        case .byte:     return "B"
        case .word:     return "W"
        case .longword: return "C"
        case .single:   return "F"
        case .double:   return "D"
        case .extended: return "E"
        }
    }

    /// How many bytes this type occupies (`GetDataSize`, 0x47E4E8).
    ///
    /// Ten for `extended` is x86 80-bit `Extended`, which is a useful check that the jump table was
    /// read correctly.
    public var size: Int {
        switch self {
        case .boolean, .shortint, .byte:   return 1
        case .smallint, .word:             return 2
        case .longint, .longword, .single: return 4
        case .int64, .double:              return 8
        case .extended:                    return 10
        }
    }

    /// The type a `.pcc` `TYPE` attribute names, if it is one of these.
    public init?(code: Character) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }
}

/// A `TPinValue`: a type byte followed by its payload.
///
/// `ZeroPinValue` (0x47D474) writes the type byte at offset 0 and zeroes offsets 1…8, so the payload
/// is **8 bytes** whatever the type; `SmallIntPinValue` (0x47D488) and `LongIntPinValue` (0x47D490)
/// then store a word or dword at offset 1 with the matching type byte.
///
/// One thing this deliberately does not model: `TPCCCompilation.Write` (0x423284) copies **11** bytes
/// of the value into its local, which 9 bytes does not account for. That is unexplained rather than
/// absent, so the struct here stays at the size the three writers above prove.
public struct PLCValue: Equatable, Sendable {
    public var type: PLCDataType
    /// Always 8 bytes, little-endian, as `ZeroPinValue` lays it out.
    public var payload: [UInt8]

    public static let payloadSize = 8

    public init(type: PLCDataType, payload: [UInt8] = Array(repeating: 0, count: PLCValue.payloadSize)) {
        self.type = type
        var bytes = payload
        if bytes.count < Self.payloadSize {
            bytes.append(contentsOf: repeatElement(0, count: Self.payloadSize - bytes.count))
        }
        self.payload = Array(bytes.prefix(Self.payloadSize))
    }

    /// The whole value as it sits in memory: the type byte, then the payload.
    public var bytes: [UInt8] { [type.rawValue] + payload }

    private func signed(_ width: Int) -> Int64 {
        let raw = payload.prefix(width).enumerated().reduce(UInt64(0)) { acc, pair in
            acc | (UInt64(pair.element) << (8 * pair.offset))
        }
        // Sign-extend from the field width.
        let shift = 64 - 8 * width
        return Int64(bitPattern: (raw << shift)) >> shift
    }

    private func unsigned(_ width: Int) -> UInt64 {
        payload.prefix(width).enumerated().reduce(UInt64(0)) { acc, pair in
            acc | (UInt64(pair.element) << (8 * pair.offset))
        }
    }

    public var intValue: Int64? {
        switch type {
        case .boolean:  return payload[0] != 0 ? 1 : 0
        case .shortint: return signed(1)
        case .smallint: return signed(2)
        case .longint:  return signed(4)
        case .int64:    return signed(8)
        case .byte:     return Int64(payload[0])
        case .word:     return Int64(unsigned(2))
        case .longword: return Int64(unsigned(4))
        case .single, .double, .extended: return nil
        }
    }

    public var doubleValue: Double? {
        switch type {
        case .single:
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: unsigned(4))))
        case .double:
            return Double(bitPattern: unsigned(8))
        case .extended:
            // 80-bit extended has no Swift counterpart; the 10 bytes are kept verbatim.
            return nil
        default:
            return intValue.map(Double.init)
        }
    }
}
