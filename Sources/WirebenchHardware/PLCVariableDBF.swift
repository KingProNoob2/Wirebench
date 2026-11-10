import Foundation

/// Dirigo's variable table as the `.dbf` it writes beside a project.
///
/// `TPCCProject.ExportFileVariables` writes the same `TPCCVariable` rows twice: through `TDBFTable` as
/// this dBase III file, and as the `.csv` that `PLCProjectCompiler.csv(fromSymbols:)` reproduces. The
/// two carry the same twenty columns in the same order, and the CSV's quoting already follows this
/// file's field types — so the CSV is the readable form of the same export, not a different one.
///
/// The encoding is dBase's *binary* one, which is not what a naive `.dbf` reader assumes:
///
/// * integers (`I`, 4 bytes) and doubles (`O`, 8 bytes) are **big-endian with the sign bit flipped**,
///   so that comparing the bytes compares the numbers. `ID = 1101` is `80 00 04 4D`, `OWNER = -1` is
///   `7F FF FF FF`, `K = 1.0` is `BF F0 00 00 00 00 00 00`.
/// * **all-zero bytes mean "not set", which is not the same as zero.** A real `0` is `80 00 00 00` and
///   a real `0.0` is `80 00 00 00 00 00 00 00`; `COLINDEX` is the first of those and `K_ADR` the
///   second is zeros, which is why the CSV prints `0` for one and nothing at all for the other.
/// * character fields (`C`) are space-padded to their width, so an empty one is all spaces.
///
/// The header carries the day it was written, so two exports of one project differ in three bytes.
/// Callers that need to reproduce a file pass its date; the app passes today's.
public enum PLCVariableDBF {

    /// The day the header stamps, as the file stores it: the year counts from 1900.
    public struct DateStamp: Equatable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public init(_ date: Date = Date(), calendar: Calendar = .current) {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            self.init(year: parts.year ?? 1900, month: parts.month ?? 1, day: parts.day ?? 1)
        }

        /// The stamp a real file carries, read back out of its header.
        public init?(bytes: [UInt8]) {
            guard bytes.count >= 4 else { return nil }
            self.init(year: 1900 + Int(bytes[1]), month: Int(bytes[2]), day: Int(bytes[3]))
        }
    }

    /// What goes in one field. `.unset` is written as zero bytes, which is the file's "no value here"
    /// and is deliberately distinct from `.integer(0)` and `.double(0)`.
    enum Value: Equatable, Sendable {
        case integer(Int)
        case double(Double)
        case text(String)
        case unset
    }

    /// dBase field types, as the ASCII letters the descriptors store.
    static let integerType: UInt8 = 0x49   // 'I'
    static let characterType: UInt8 = 0x43 // 'C'
    static let doubleType: UInt8 = 0x4F    // 'O'

    /// A column's type and width. The order and the names come from `PLCProjectCompiler.symbolColumns`,
    /// which is the CSV's too, so the two files cannot drift apart.
    static func field(named column: String) -> (type: UInt8, width: Int) {
        switch column {
        case "NAME": return (characterType, 40)
        case "POPIS": return (characterType, 100)
        case "UMISTENI", "SVORKA", "INFO1", "INFO2", "INFO3": return (characterType, 16)
        case "DATA", "K", "Q": return (doubleType, 8)
        default: return (integerType, 4)
        }
    }

    /// The columns with their descriptors, in file order.
    public static var fields: [(name: String, type: UInt8, width: Int)] {
        PLCProjectCompiler.symbolColumns.map {
            let field = self.field(named: $0)
            return (name: $0, type: field.type, width: field.width)
        }
    }

    /// The whole file: a 32-byte header, one 32-byte descriptor per column, the terminator, one record
    /// per row, and the `0x1A` end-of-file byte.
    public static func bytes(fromSymbols rows: [PLCProjectCompiler.Symbol],
                             exportedOn date: DateStamp) -> [UInt8] {
        let columns = PLCProjectCompiler.symbolColumns
        let headerLength = 32 + 32 * columns.count + 1
        let recordLength = 1 + columns.reduce(0) { $0 + field(named: $1).width }

        var out: [UInt8] = []
        out.reserveCapacity(headerLength + rows.count * recordLength + 1)

        out.append(0x03)                                        // dBase III, no memo file
        out.append(UInt8(truncatingIfNeeded: date.year - 1900))
        out.append(UInt8(truncatingIfNeeded: date.month))
        out.append(UInt8(truncatingIfNeeded: date.day))
        appendLittleEndian(UInt32(rows.count), count: 4, into: &out)
        appendLittleEndian(UInt32(headerLength), count: 2, into: &out)
        appendLittleEndian(UInt32(recordLength), count: 2, into: &out)
        out.append(contentsOf: [UInt8](repeating: 0, count: 16)) // reserved, 0x0C...0x1B
        out.append(0x00)                                        // no MDX index
        out.append(0x1F)                                        // language driver, as Dirigo writes it
        out.append(contentsOf: [UInt8](repeating: 0, count: 2))  // reserved

        for column in columns {
            let field = field(named: column)
            let name = Array(column.utf8).prefix(11)
            out.append(contentsOf: name)
            out.append(contentsOf: [UInt8](repeating: 0, count: 11 - name.count))
            out.append(field.type)
            out.append(contentsOf: [UInt8](repeating: 0, count: 4))  // field data address, unused
            out.append(UInt8(field.width))
            out.append(0)                                            // decimal count
            out.append(contentsOf: [UInt8](repeating: 0, count: 14)) // reserved
        }
        out.append(0x0D)

        for row in rows {
            out.append(0x20)                                        // deletion flag: not deleted
            for column in columns {
                append(value(of: column, in: row),
                       width: field(named: column).width, into: &out)
            }
        }

        out.append(0x1A)
        return out
    }

    /// The row's value for one column.
    ///
    /// The three doubles and the two address integers are text on `Symbol`, because that is what the
    /// CSV carries, and empty means the column was never set — which is `.unset`, not zero.
    static func value(of column: String, in row: PLCProjectCompiler.Symbol) -> Value {
        func optionalDouble(_ text: String) -> Value {
            text.isEmpty ? .unset : (Double(text).map(Value.double) ?? .unset)
        }
        func optionalInteger(_ text: String) -> Value {
            text.isEmpty ? .unset : (Int(text).map(Value.integer) ?? .unset)
        }
        switch column {
        case "ID": return .integer(row.id)
        case "OWNER": return .integer(row.owner)
        case "DRIVER": return .integer(row.driver)
        case "TYP": return .integer(row.type)
        case "INDEX": return .integer(row.index)
        case "ROWINDEX": return .integer(row.rowIndex)
        case "COLINDEX": return .integer(row.colIndex)
        case "RIGHTS": return .integer(row.rights)
        case "NAME": return .text(row.name)
        case "POPIS": return .text(row.popis)
        case "UMISTENI": return .text("\(row.umisteni)")
        case "SVORKA": return .text("\(row.svorka)")
        case "INFO1": return .text(row.info1)
        case "INFO2": return .text(row.info2)
        case "INFO3": return .text(row.info3)
        case "DATA": return optionalDouble(row.data)
        case "K": return optionalDouble(row.k)
        case "Q": return optionalDouble(row.q)
        case "K_ADR": return optionalInteger(row.kAdr)
        case "Q_ADR": return optionalInteger(row.qAdr)
        default: return .unset
        }
    }

    /// One field's bytes: the sign-flipped big-endian number, or the text padded out to the width.
    static func append(_ value: Value, width: Int, into out: inout [UInt8]) {
        switch value {
        case .unset:
            out.append(contentsOf: [UInt8](repeating: 0, count: width))
        case .integer(let number):
            let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: number)) ^ 0x8000_0000
            appendBigEndian(UInt64(bits), count: 4, into: &out)
        case .double(let number):
            appendBigEndian(number.bitPattern ^ 0x8000_0000_0000_0000, count: 8, into: &out)
        case .text(let string):
            var bytes = Array(string.utf8)
            if bytes.count > width { bytes = Array(bytes.prefix(width)) }
            out.append(contentsOf: bytes)
            out.append(contentsOf: [UInt8](repeating: 0x20, count: width - bytes.count))
        }
    }

    private static func appendLittleEndian(_ value: UInt32, count: Int, into out: inout [UInt8]) {
        for index in 0..<count { out.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    private static func appendBigEndian(_ value: UInt64, count: Int, into out: inout [UInt8]) {
        for index in stride(from: count - 1, through: 0, by: -1) {
            out.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }
}
