import Foundation

/// Builds the program table's module records — the program itself, as the PLC receives it.
///
/// Every part of this is traced to an artefact:
///
/// * the record shape `[id: u8][flag: u8]` then one `u16` per value, from the controlled export diff
///   (`had.dmp` vs `had+1block.dmp`, where an added `TMDigitalOutputs` produced `0a 80` + eight `u16`s)
///   and from the first record of `had.dmp` (`10` = `TMPulseGenerator`, the class `PulseGen1` resolves to);
/// * the pin encoding `(UMISTENI << 8) | SVORKA`, from a join of the table against Dirigo's own symbol
///   table (`had+1block.csv`): `Counter1` carries `0x0700`, which the CSV names as `Or1.Y` with
///   `UMISTENI=7, SVORKA=0` — and `0x0200`, named `zapnuti.Y`;
/// * `0xC0xx` a **constant**, `0xC000 | value` — from `TMP1Module.InPinBinaryOutput` (P1.bpl 0x40D3F4),
///   which ends `andw $0x3fff, %bx; orw $0xc000, %bx` (0x40D716) for an input pin with no source. It is
///   **not** "unassigned": `0xC000` is the constant 0, which is what an unwired pin carries. Verified
///   against the project file: `SystemCmd1`'s `IN_PIN VALUE="770"` is `0xC302`, its `PARAM_PIN VALUE="112"`
///   is `0xC070`, `PulseGen1`'s two `PARAM_PIN VALUE="3"` are `0xC003`, and `ISwitch1`'s mask inputs
///   `1,2,4,8,16,32` are `0xC001`…`0xC020`;
/// * `0x10xx` an int slot, `0x20xx` a long slot, `0x30xx` a float slot, from the same routine's other
///   branches (`addw $0x1000/$0x2000/$0x3000, %ax`);
/// * the record region `0x40..0xA2` (98 bytes) followed by zero padding to the `0xFFFF` sentinel at
///   `0xC4`, from the same export diff.
///
/// The `flag` byte is the OR of `pin[0x70]` over the class's *hidden* in-pins
/// (`TMP1Module.ExportFile` stage 8, P1.bpl 0x40DE0E), so it is a per-class constant rather than project
/// data. The observed values are recorded in `docs/plc-protocol.md`; it is carried here, not computed.
public struct PLCProgramBuilder: Sendable {
    /// One module, in compile order.
    public struct Module: Equatable, Sendable {
        /// The block id, from `docs/block-ids.json`. `0` for a block with no PLC routine — a wiring or
        /// logic block that is folded into its neighbours.
        public var id: UInt8
        /// The record's second byte. Carried; its meaning is not established.
        public var flag: UInt8
        /// One value per pin, already resolved to `(UMISTENI << 8) | SVORKA`, `0xC000 | constant`,
        /// `0x1000/0x2000/0x3000 + index` or `0`.
        public var values: [UInt16]

        public init(id: UInt8, flag: UInt8 = 0, values: [UInt16] = []) {
            self.id = id
            self.flag = flag
            self.values = values
        }

        /// A reference to another module's terminal.
        public static func terminal(umisteni: UInt8, svorka: UInt8) -> UInt16 {
            (UInt16(umisteni) << 8) | UInt16(svorka)
        }

        /// A pin's constant value: `0xC000 | value`, from `InPinBinaryOutput` (P1.bpl 0x40D716).
        ///
        /// An unwired pin is `constant(0)` — `0xC000` — not "unassigned"; the encoder has no unassigned
        /// state, only a constant, and 0 is its default.
        public static func constant(_ value: Int) -> UInt16 {
            0xC000 | UInt16(truncatingIfNeeded: value) & 0x3FFF
        }

        /// `constant(0)`, the word an unwired pin carries. Kept under its old name because the
        /// correction it records — `0xC0xx` is a constant, not "unassigned" — is worth the rename.
        @available(*, deprecated, renamed: "constant(_:)")
        public static let unassigned: UInt16 = 0xC000
    }

    public var modules: [Module]

    public init(modules: [Module] = []) {
        self.modules = modules
    }

    /// The records region: every module's record, back to back, with no padding.
    public func records() -> [UInt8] {
        var out: [UInt8] = []
        for module in modules {
            out.append(module.id)
            out.append(module.flag)
            for value in module.values {
                out.append(UInt8(truncatingIfNeeded: value))
                out.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        return out
    }

    /// How many bytes the records occupy. The real tables use 98 (`0x40..0xA2`) for `had.pcc` and 482 for
    /// the captured 640-byte upload.
    public var recordsLength: Int { modules.reduce(0) { $0 + 2 + 2 * $1.values.count } }

    /// Places the records into a table template, sized to the records, and recomputes the checksum.
    ///
    /// The header and trailer come from the template because their fields are project metadata
    /// (version, the three project flags, the profile name) rather than program content. Only the
    /// records and the checksum are the program.
    public func table(fromTemplate template: PLCProgramTable) -> [UInt8] {
        PLCProgramTable.assemble(template: template, records: records())
    }
}
