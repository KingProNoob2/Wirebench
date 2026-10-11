import Foundation

/// Compiles a Dirigo project into the program table the PLC runs.
///
/// Every rule here comes from an artefact; none is invented.
///
/// * The project file is Dirigo's own XML. Each `<MODULE>` carries a `GUID` (the block class), an `ID`
///   (its `UMISTENI`), an `ORDER` (the compile order) and its `IN_PIN`/`OUT_PIN` elements.
/// * `<CONNECTION IN_MODULE_ID= IN_PIN_ID= OUT_MODULE_ID= OUT_PIN_ID=>` is a wire; the value it
///   contributes is `(OUT_MODULE_ID << 8) | OUT_PIN_ID`.
/// * A record's first byte is its class's id, or `0` when the class has none. `docs/block-ids.json`.
/// * A record's length is the class's own value count. `docs/class-shapes.json`. Two classes
///   (`TMInt2Bits` and the segment class) contribute **no record at all** — two byte-identical exports
///   prove it.
/// * The value families, from `TMP1Module.InPinBinaryOutput` / `OutPinBinaryOutput` (P1.bpl 0x40D3F4 /
///   0x40DF68): a terminal `(module << 8) | terminal`, `0x1000/0x2000/0x3000 + index` for a typed slot,
///   and **`0xC000 | constant`** for a pin that is not wired. `0xC000` is the *constant 0*, not
///   "unassigned"; the encoder has no unassigned state. Verified against the project file: `SystemCmd1`'s
///   `IN_PIN 770` is `0xC302`, its `PARAM_PIN 112` is `0xC070`.
/// * The checksum is CRC-16 poly `0xA001`, seed `0xFFFF`, inverted, over the table with that field zero.
///
/// **Not established**: the meaning of the second byte (`flag`) beyond that it is the OR of `pin[0x70]`
/// over a class's hidden in-pins — so it is a per-class constant, carried here — and how the sheet's pins
/// map onto the three lists the writer walks (`module+0x7C`, `+0x84`, `+0x80`). That last gap is why
/// `constants` is caller-supplied: the *order* in which a class consumes its constants is the class's, and
/// only `had.dmp` pins it for the classes in `had.pcc`.
///
/// **Status: written, only partly verified.** The parsing is tested against `had+1block.pcc` (12 modules,
/// 20 wires, the ORDER and the module IDs). The record *shape* — boundaries, ids, slot positions — is
/// verified against `had.dmp`; the record *values* are verified for the constant-carrying positions, and
/// not for the wired ones, where the class's pin order is still to be read from `P1.bpl`.
public struct PLCProjectCompiler {
    /// What is known about one block class.
    public struct ClassShape: Sendable, Equatable {
        /// How a position in the record is filled.
        public enum Role: Sendable, Equatable {
            /// Fed by a wire, in pin order.
            case wire
            /// A data slot, `0x1000 + the module's ROWINDEX` from the symbol table.
            case slot
            /// The module's own terminal, `(umisteni << 8) | svorka` — what an output pin of a Boolean
            /// type carries (`OutPinBinaryOutput`, P1.bpl 0x40DFD7).
            case terminal(umisteni: UInt8, svorka: UInt8)
            /// The pin's **own allocated** terminal: `(INDEX << 8) | ROWINDEX` of the out-pin at `svorka`,
            /// which is what `OutPinBinaryOutput` (P1.bpl 0x40DF68) writes for a Boolean out-pin. Unlike
            /// `.terminal`, the numbers come from the allocation rather than from the shape, so it is the
            /// role the decomp-derived table uses.
            case ownTerminal(svorka: Int)
            /// An in-pin the class feeds from **its own** out-pin `svorka`.
            ///
            /// `TMCounter`'s third input has no `<CONNECTION>` in `had.pcc`, yet `had.dmp` carries `0200`
            /// there. `0200` is `(INDEX 2, ROWINDEX 0)`, and looking that up in the table this compiler
            /// generates finds `Counter1`'s *own* out-pin 0 — the hidden `LastState`, which has no symbol
            /// row because it is unexported. So the word is the module's own terminal, and it is a rule of
            /// the class rather than anything the sheet says.
            case feedback(svorka: Int)
            /// A **hidden** pin: it emits no value at all and ORs its `pin[0x70]` byte into the record's
            /// second byte. `InPinToStream` (P1.bpl 0x40DDE4) is explicit — for a hidden pin with the
            /// caller's level `>= 2` it does `orw %dx, (%eax)` and jumps past the `Write` (0x40DE0E).
            /// That is what the "flag" byte is.
            case hidden(UInt8)
            /// Not fed by a wire: the pin's **constant**, `0xC000 | value`, which is `0xC000` when the
            /// project gives no value. It is not an "unassigned" state — the encoder has none.
            case unassigned
        }
        /// The record's first byte.
        public var id: UInt8?
        /// One role per `u16` the record carries, in order, with `.hidden` entries emitting nothing.
        /// `contributesRecord == false` means the class produces nothing at all, whatever the roles say.
        public var roles: [Role]
        public var contributesRecord: Bool
        /// The class writes **one word per out-pin**, the i-th being that pin's own allocated terminal.
        /// `TMDigitalInputs` does exactly that — `ExportFile` (P1.bpl 0x41AEEC) walks an array of pin
        /// pointers and sets `pin[0x64] = i`, `pin[0x60] = pin[0x68]` — so the record's length follows the
        /// project's configured pin count rather than a fixed role list.
        public var dynamicOutPins: Bool
        /// The words the record carries: every role except `.hidden`.
        public var valueCount: Int { roles.filter { $0 != .hidden(0) }.count }
        public init(id: UInt8?, roles: [Role], contributesRecord: Bool = true,
                    dynamicOutPins: Bool = false) {
            self.id = id; self.roles = roles; self.contributesRecord = contributesRecord
            self.dynamicOutPins = dynamicOutPins
        }
        /// A class whose positions are all fed by wires.
        public init(id: UInt8?, valueCount: Int, contributesRecord: Bool = true) {
            self.init(id: id, roles: Array(repeating: .wire, count: valueCount),
                      contributesRecord: contributesRecord)
        }
    }

    /// The role lists for the classes in `had.pcc`, **verified byte for byte** against `had.dmp`.
    ///
    /// These are the mapping the writer's code implies, written out per class: one role per word the
    /// record carries, in the order `TMP1Module.ExportFile` stage 8 walks (`module+0x7C`, then `+0x84`,
    /// then the out-pins at `+0x80`). The *values* that fill them come from the project file (constants),
    /// the symbol table (slots and terminals) and the wiring; the lists only say which value lands where,
    /// and `Tests/DirigoSwiftTests/ProjectCompilerTests.swift`'s *Record reproduction* suite asserts that
    /// they rebuild all nine records of `had.dmp` byte for byte.
    ///
    /// The flag byte is deliberately absent: it is the module's hidden pins' own values, not a class
    /// property (the two `TMBoolVar`s carry `0x00` and `0xC0`), so it travels on `Module.flag`.
    /// The whole library: `classShapesFromP1` (read out of `P1.bpl`) with the nine entries `had.dmp`
    /// verifies laid over it. The nine win because for three of them the decomp's own counts are known to
    /// miss (`TMCounter`, `TMComparator`, `TMIntSwitch`), and because their `.terminal` words are pinned
    /// against the dump.
    /// Entries read from a class's own `ExportFile`, for the 24 classes that override the base writer.
    /// `TMDigitalInputs.ExportFile` (P1.bpl 0x41AEEC) is the first: it walks an array of up to sixteen pin
    /// pointers and gives each one `pin[0x64] = i` and `pin[0x60] = pin[0x68]`, so the class's record is
    /// one word per out-pin — its own terminal — for however many the project configures.
    public static let classShapesFromOverrides: [String: ClassShape] = [
        "TMDigitalInputs": .init(id: 9, roles: [], dynamicOutPins: true),
        // The display classes are modules in the sheet but not part of the program: `had.pcc` holds a
        // `Segment1` whose module is present, and `had.dmp`'s record walk accounts for the other nine
        // modules and neither of the two displays. Saying so explicitly is what lets a build report tell
        // "writes no record" apart from "no shape yet".
        "TDispSegmentModule": .init(id: nil, roles: [], contributesRecord: false),
    ]

    public static let classShapes: [String: ClassShape] = {
        var merged = classShapesFromP1
        for (cls, shape) in classShapesFromOverrides { merged[cls] = shape }
        for (cls, shape) in hadProjectShapes { merged[cls] = shape }
        return merged
    }()

    public static let hadProjectShapes: [String: ClassShape] = {
        let wire = ClassShape.Role.wire
        return [
            // PulseGen1: its own Cnt terminal as a wire, then its two declared constants, then the slot.
            "TMPulseGenerator": .init(id: 16, roles: [wire, .unassigned, .unassigned, .slot]),
            "TMBoolVar":        .init(id: nil, roles: []),
            // Its third input is fed by its own hidden `LastState` out-pin — see `Role.feedback`. With a
            // plain `wire` there, an unconnected pin wrote constant 0 and the record differed from
            // `had.dmp` in exactly that word.
            "TMCounter":        .init(id: 15, roles: [wire, wire, .feedback(svorka: 0), .slot]),
            "TMDigitalOutputs": .init(id: 10, roles: Array(repeating: wire, count: 8)),
            // Six source wires, then its six **masks** as declared constants, then the slot. The masks
            // were `wire`s here because the dump test fed their values in as wires; a real build has no
            // wire for them at all and takes them from the project's `IN_PIN` values (`1, 2, 4, 8, 16,
            // 32`), which is what `had.dmp` carries as `C001 C002 C004 C008 C010 C020`. A build that
            // treated them as wires wrote `C000` six times.
            "TMIntSwitch":      .init(id: nil,
                                      roles: Array(repeating: wire, count: 6)
                                          + Array(repeating: .unassigned, count: 6) + [.slot]),
            // Comparator1: a slot from elsewhere, its constant, two terminals, then its own output.
            // The out-pin writes its *own allocated* terminal. `had.dmp` alone made it look like a fixed
            // pair — `Comparator1` is module 6 and `Or1` module 7 there — but in `kostička` the same
            // classes are modules 6 and 2 and their terminals are different, which is what a
            // cross-project check caught.
            // One wire (its `<CONNECTION>`), one constant, then its **three** own out-pin terminals —
            // `AGtB`, `AEqB` and `ALtB`, which `had.dmp` carries as `0400 0500 0600`. They used to be
            // written as two `wire`s plus one terminal, because the old hand-fed test path had no
            // allocation to resolve an out-pin's address from; it does now, so the shape says what it means.
            "TMComparator":     .init(id: 6, roles: [wire, .unassigned, .ownTerminal(svorka: 0),
                                                     .ownTerminal(svorka: 1), .ownTerminal(svorka: 2)]),
            "TMOr":             .init(id: 20, roles: [wire, wire, .ownTerminal(svorka: 0)]),
            "TSystemCommand":   .init(id: 81, roles: [.unassigned, .unassigned, .slot]),
            // Two classes compile to nothing at all: two byte-identical exports prove it.
            "TMInt2Bits":       .init(id: nil, roles: [], contributesRecord: false),
        ]
    }()

    public struct Module: Equatable, Sendable {
        public var name: String
        public var guid: String
        public var umisteni: UInt8
        public var order: Int
        public var inPinCount: Int
        public var outPinCount: Int
        /// The module's position in the project file. `modules(in:)` hands the list back in `ORDER` order,
        /// but the symbol table's **rows** are written in file order (`kostička.pcc` lists `ISwitch1`
        /// first and its `.csv` starts with `ISwitch1.Y`, though `ISwitch1` is module 5), while the
        /// allocation runs in ascending module `ID`. Both orders are needed, so both are kept.
        public var fileIndex: Int
        /// The constant values this module's non-wired pins carry, **in the order the class consumes
        /// them** — `TMP1Module.InPinBinaryOutput` (P1.bpl 0x40D3F4) emits `0xC000 | value` for a pin with
        /// no source. The order is the class's own registration, so the adapter supplies this list rather
        /// than the parser: `had.dmp` fixes it for the classes in `had.pcc`
        /// (`TSystemCommand` is `[770, 112]`, from the project's second `IN_PIN` and first `PARAM_PIN`).
        public var constants: [Int]
        /// The record's second byte for this module. It is the OR of the module's own **hidden** pins'
        /// `pin[0x70]` values (`InPinToStream`, P1.bpl 0x40DE0E), so it is per *instance*: the two
        /// `TMBoolVar`s in `had.pcc` carry `0x00` (`zapnuti`) and `0xC0` (`reset`). The class's shape can
        /// also contribute bits through `.hidden`, and the two are OR-ed.
        public var flag: UInt8

        public init(name: String, guid: String, umisteni: UInt8, order: Int,
                    inPinCount: Int, outPinCount: Int, fileIndex: Int = 0,
                    constants: [Int] = [], flag: UInt8 = 0) {
            self.name = name; self.guid = guid; self.umisteni = umisteni; self.order = order
            self.inPinCount = inPinCount; self.outPinCount = outPinCount
            self.fileIndex = fileIndex; self.constants = constants; self.flag = flag
        }
    }

    public struct Wire: Equatable, Sendable {
        public var inModule: UInt8, inPin: Int, outModule: UInt8, outPin: Int
        /// The value this wire contributes to the destination module's record.
        public var value: UInt16 { (UInt16(outModule) << 8) | UInt16(outPin) }
    }

    public let shapes: [String: ClassShape]
    public let classForGUID: [String: String]

    public init(shapes: [String: ClassShape], classForGUID: [String: String]) {
        self.shapes = shapes; self.classForGUID = classForGUID
    }

    // MARK: - Parsing

    public static func modules(in xml: String) -> [Module] {
        matches(#"<MODULE\b[^>]*>"#, in: xml).enumerated().compactMap { position, tag in
            guard let guid = attribute("GUID", tag)?.uppercased(),
                  let name = attribute("NAME", tag),
                  let id = attribute("ID", tag).flatMap(UInt8.init),
                  let order = attribute("ORDER", tag).flatMap(Int.init) else { return nil }
            let body = body(of: tag, in: xml)
            return Module(name: name, guid: guid, umisteni: id, order: order,
                          inPinCount: matches(#"<IN_PIN\b"#, in: body).count,
                          outPinCount: matches(#"<OUT_PIN\b"#, in: body).count,
                          fileIndex: position,
                          constants: declaredConstants(module: id, body: body, in: xml))
        }
        // Execution order, with a documented tie-break: `had.pcc` lists `reset` (ORDER 40, id 4) before
        // `8xDO1` (ORDER 40, id 10), and `had.dmp` has them the other way round. Ordering by `id`
        // ascending matches 66 of the 98 record bytes; descending matches 70 — and only the record region
        // depends on this, because the symbol table sorts its own rows by `(umisteni, order)`.
        .sorted { ($0.order, -Int($0.umisteni)) < ($1.order, -Int($1.umisteni)) }
    }

    /// The constants a module's record carries, read from the project.
    ///
    /// Every `IN_PIN`/`PARAM_PIN` has a `VALUE`, and the ones that reach the record are the *unconnected*
    /// pins whose value is non-zero, in document order — except the first `IN_PIN`, which the projects use
    /// as the "input present" flag (`VALUE="1"` on every module). Verified against the four modules whose
    /// records `had.dmp` fixes: `PulseGen1` `[3, 3]` (its two `PARAM_PIN`s, the `IN_PIN 0` being zero),
    /// `Comparator1` `[6]` (its *third* `IN_PIN`), `SystemCmd1` `[770, 112]` (its second `IN_PIN` and first
    /// `PARAM_PIN`), and `ISwitch1` `[1, 2, 4, 8, 16, 32]` (the six masks its record carries).
    static func declaredConstants(module id: UInt8, body: String, in xml: String) -> [Int] {
        var connected = Set<Int>()
        for tag in matches(#"<CONNECTION\b[^>]*>"#, in: xml) {
            if attribute("IN_MODULE_ID", tag).flatMap(UInt8.init) == id,
               let pin = attribute("IN_PIN_ID", tag).flatMap(Int.init) {
                connected.insert(pin)
            }
        }
        var out: [Int] = []
        for (index, tag) in matches(#"<(?:IN_PIN|PARAM_PIN)\b[^>]*>"#, in: body).enumerated() {
            if index == 0 { continue }                     // the "input present" flag
            if connected.contains(index + 1) { continue }  // a wire wins over the declared value
            guard let value = attribute("VALUE", tag).flatMap(Int.init), value != 0 else { continue }
            out.append(value)
        }
        return out
    }

    public static func wires(in xml: String) -> [Wire] {
        matches(#"<CONNECTION\b[^>]*>"#, in: xml).compactMap { tag in
            guard let i = attribute("IN_MODULE_ID", tag).flatMap(UInt8.init),
                  let ip = attribute("IN_PIN_ID", tag).flatMap(Int.init),
                  let o = attribute("OUT_MODULE_ID", tag).flatMap(UInt8.init),
                  let op = attribute("OUT_PIN_ID", tag).flatMap(Int.init) else { return nil }
            return Wire(inModule: i, inPin: ip, outModule: o, outPin: op)
        }
    }

    // MARK: - Compiling

    /// The program records, in compile order: `[id][flag]` then one `u16` per value.
    ///
    /// Each value is filled from the wires into that module, in pin order; a pin with no wire carries its
    /// **constant** — `0xC000 | value` from the module's `constants`, or `0xC000` (constant 0) when the
    /// adapter supplies none. `0xC000` is *not* an "unassigned" marker: `TMP1Module.InPinBinaryOutput`
    /// (P1.bpl 0x40D3F4) emits `0xC000 | value` and has no unassigned case.
    public func records(modules: [Module], wires: [Wire],
                        slots: [String: UInt16] = [:]) throws -> [UInt8] {
        // An allocation is built even on this path, which exists for callers that hand in the slot
        // numbers. Roles that need an *allocated* address — `.ownTerminal`, `.feedback` — would otherwise
        // fall back to `(umisteni << 8) | svorka`, which is only right when a project's module ids happen
        // to line up with its pins' `INDEX` column. The handed-in slots stay authoritative for `.slot`, so
        // the values the caller supplied are still the values written.
        let allocation = PLCSymbolTable(modules: modules, wires: wires,
                                        classForGUID: classForGUID, shapes: shapes)
        return try records(modules: modules, wires: wires, slots: slots, wireValue: { $0.value },
                           allocation: allocation)
    }

    /// The same, with the slots **and** the wire values taken from a generated `PLCSymbolTable` rather
    /// than from a supplied CSV and hand-encoded wires.
    ///
    /// This is what makes the compiler need no symbol table of its own: a wire contributes the *source
    /// pin's* `(INDEX, ROWINDEX)` — `(pin[0x64] << 8) | pin[0x60]` for a Boolean, `0x1000 + pin[0x60]`
    /// for a word — and those are exactly the two numbers the same generator writes into the CSV.
    public func records(modules: [Module], wires: [Wire], allocation: PLCSymbolTable) throws -> [UInt8] {
        // A wire whose source has no allocated address is one the generator cannot place: the source is a
        // *macro* module (a sheet saved as a block), whose internals are not in this library. Writing the
        // raw `(module << 8) | pin` there would put a terminal in the table that the symbol table does not
        // have, so it becomes constant 0 — the encoder's own "no source" value — and the record stays
        // consistent with the table.
        try records(modules: modules, wires: wires, slots: allocation.slots,
                    wireValue: { allocation.value(fromWire: $0) ?? PLCProgramBuilder.Module.constant(0) },
                    allocation: allocation)
    }

    private func records(modules: [Module], wires: [Wire], slots: [String: UInt16],
                         wireValue: (Wire) -> UInt16,
                         allocation: PLCSymbolTable? = nil) throws -> [UInt8] {
        var byInput: [UInt8: [Int: UInt16]] = [:]
        for w in wires { byInput[w.inModule, default: [:]][w.inPin] = wireValue(w) }

        var out: [UInt8] = []
        for m in modules {
            // Brace-insensitive: the project writes `{ABC}`, the id table stores `ABC`.
            let cls = classForGUID[Self.normaliseGUID(m.guid)] ?? classForGUID[m.guid] ?? "?"
            guard let shape = shapes[cls] else { continue }
            guard shape.contributesRecord else { continue }
            // The record's second byte is not a flag of the program's: it is the OR of the hidden
            // in-pins' `pin[0x70]` values (`InPinToStream`, P1.bpl 0x40DE0E), so it comes out of the
            // class's own shape before any word is written.
            let flag = m.flag | shape.roles.reduce(UInt8(0)) { acc, role in
                if case .hidden(let bits) = role { return acc | bits }
                return acc
            }
            out.append(shape.id ?? 0)
            out.append(flag)
            let feeds = byInput[m.umisteni] ?? [:]
            var pin = 1
            var next = 0
            /// The next constant the class would place, or constant 0 when the adapter supplied none.
            func constant() -> UInt16 {
                defer { next += 1 }
                return next < m.constants.count
                    ? PLCProgramBuilder.Module.constant(m.constants[next])
                    : PLCProgramBuilder.Module.constant(0)
            }
            // A `dynamicOutPins` class writes one word per **sheet** out-pin (`TMDigitalInputs` walks the
            // module's own pin array). An ordinary class's count is *not* the sheet's: `8xDO1` shows seven
            // `<IN_PIN>` elements and its record has eight words, because `TMDigitalOutputs` registers
            // eight channels and the class's count is what the writer walks.
            let roles = shape.dynamicOutPins
                ? (0..<m.outPinCount).map { ClassShape.Role.ownTerminal(svorka: $0) }
                : shape.roles
            for role in roles {
                if case .hidden = role { continue }   // a hidden pin sets the flag and writes nothing
                let value: UInt16
                switch role {
                case .slot:
                    // `0x1000 + ROWINDEX` of the module's own symbol row, from Dirigo's symbol table.
                    value = slots[m.name].map { 0x1000 + $0 } ?? PLCProgramBuilder.Module.constant(0)
                case .terminal(let umisteni, let svorka):
                    value = PLCProgramBuilder.Module.terminal(umisteni: umisteni, svorka: svorka)
                case .feedback(let svorka):
                    // The module's own out-pin `svorka`, through the same allocation the symbol table is
                    // generated from. Unlike `ownTerminal` this is deliberately *not* a sheet pin: it is
                    // the class closing a loop on itself, so it neither advances the wire index nor is
                    // supplied by the adapter.
                    value = allocation?.addresses[UInt16(m.umisteni) << 8 | UInt16(svorka)]?.word
                        ?? PLCProgramBuilder.Module.terminal(umisteni: m.umisteni, svorka: UInt8(svorka))
                case .ownTerminal(let svorka):
                    // The pin's own address, from the same allocation the symbol table is generated from.
                    // Without one — the hand-fed-wire path older tests use — fall back to `(umisteni << 8)
                    // | svorka`, which is what that path assumed; it coincides with the allocated value
                    // only when a project's module ids happen to line up with the pins' `INDEX` column,
                    // as `had.pcc`'s do.
                    value = allocation?.addresses[UInt16(m.umisteni) << 8 | UInt16(svorka)]?.word
                        ?? PLCProgramBuilder.Module.terminal(umisteni: m.umisteni, svorka: UInt8(svorka))
                case .wire:
                    // A wire, or — when nothing feeds the pin — the pin's constant, which the encoder
                    // gives as 0 for an unset value. Only `.unassigned` positions consume `constants`,
                    // because those are the class's declared constant pins; a `.wire` position that the
                    // sheet leaves open is a pin the class still treats as a wire.
                    value = feeds[pin] ?? PLCProgramBuilder.Module.constant(0)
                    pin += 1
                case .unassigned:
                    // A class-declared constant pin is not one of the sheet's pins, so it does not
                    // advance the wire index — the same rule `.hidden` follows.
                    value = constant()
                case .hidden:
                    continue
                }
                out.append(UInt8(truncatingIfNeeded: value))
                out.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        return out
    }

    /// A whole table: the records placed into a template, padded, with the checksum recomputed.
    public func table(fromTemplate template: PLCProgramTable,
                      modules: [Module], wires: [Wire],
                      slots: [String: UInt16] = [:]) throws -> [UInt8] {
        try table(fromTemplate: template, modules: modules, wires: wires,
                  region: records(modules: modules, wires: wires, slots: slots))
    }

    /// The same, with the slots and the wire values taken from a generated `PLCSymbolTable`.
    public func table(fromTemplate template: PLCProgramTable, modules: [Module], wires: [Wire],
                      allocation: PLCSymbolTable) throws -> [UInt8] {
        try table(fromTemplate: template, modules: modules, wires: wires,
                  region: records(modules: modules, wires: wires, allocation: allocation))
    }

    private func table(fromTemplate template: PLCProgramTable, modules: [Module], wires: [Wire],
                       region: [UInt8]) throws -> [UInt8] {
        var copy = template.bytes
        let capacity = PLCProgramTable.sentinelOffset - PLCProgramTable.bodyOffset
        guard region.count <= capacity else { throw CompileError.recordsDoNotFit(region.count, capacity) }
        for i in 0..<capacity {
            copy[PLCProgramTable.bodyOffset + i] = i < region.count ? region[i] : 0
        }
        copy[PLCProgramTable.checksumOffset] = 0
        copy[PLCProgramTable.checksumOffset + 1] = 0
        let sum = PLCProgramTable.computeChecksum(copy)
        copy[PLCProgramTable.checksumOffset] = UInt8(truncatingIfNeeded: sum)
        copy[PLCProgramTable.checksumOffset + 1] = UInt8(truncatingIfNeeded: sum >> 8)
        return copy
    }

    public enum CompileError: Error, Equatable {
        case recordsDoNotFit(Int, Int)
    }

    /// `{ABC}` and `ABC` are the same GUID; the project file and the id table differ in brace style.
    public static func normaliseGUID(_ guid: String) -> String {
        guid.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }

    // MARK: - The value families, from the encoders

    /// One `u16` of the record region, classified by the family `TMP1Module`'s pin encoders emit.
    ///
    /// Everything here is read from `P1.bpl`, not inferred:
    ///
    /// * `InPinBinaryOutput` (0x40D3F4) and `OutPinBinaryOutput` (0x40DF68) emit a **terminal**
    ///   `(pin[0x64] << 8) | pin[0x60]` for a Boolean pin (0x40D49A / 0x40DFD7);
    /// * `0x1000/0x2000/0x3000 + pin[0x60]` for a Smallint/Word, Longint/Longword or Single
    ///   (0x40D506 / 0x40D51B / 0x40D530 and 0x40E034 / 0x40E040 / 0x40E04C) — the int, long and float
    ///   arrays, which is why `0x2xxx` and `0x3xxx` are slot families too, not just `0x10xx`;
    /// * `0xC000 | (constant & 0x3FFF)` for an input pin with no source (0x40D716), or the raw 16-bit
    ///   constant at `pin[0x4E]` when the pin's value type byte is 2 (0x40D68F).
    ///
    /// `0xC000` is therefore a **constant**, and the constant 0 at that — the family the doc called
    /// "unassigned" for three revisions.
    public enum Value: Equatable, Sendable {
        /// `0xC000 | v` — the constant `v`, which is 0 for an unwired pin with no value.
        case constant(UInt16)
        /// `0x1000/0x2000/0x3000 + n` — element `n` of the int, long or float array.
        case slot(index: UInt16, kind: SlotKind)
        /// `(umisteni << 8) | svorka` — a Boolean terminal.
        case terminal(umisteni: UInt8, svorka: UInt8)
        /// A literal zero, the encoder's `0` before anything is added.
        case zero
        /// A constant taken raw from the pin's value record (`pin[0x4D] == 2` → `pin[0x4E]`), which is
        /// how `ISwitch1`'s `0x941E` is produced. It overlaps the terminal family by shape, so it is
        /// named separately rather than guessed.
        case rawConstant(UInt16)

        public enum SlotKind: String, Sendable { case int = "int", long = "long", float = "float" }
    }

    /// Classifies one record word. Byte order first: the table is little-endian.
    public static func classify(_ word: UInt16) -> Value {
        switch word {
        case 0:
            return .zero
        case 0x1000..<0x2000:
            return .slot(index: word - 0x1000, kind: .int)
        case 0x2000..<0x3000:
            return .slot(index: word - 0x2000, kind: .long)
        case 0x3000..<0x4000:
            return .slot(index: word - 0x3000, kind: .float)
        default:
            // The constant family is `0xC000` upward *set*, i.e. bits 15 and 14 both set, and the value
            // is the low 14 bits (`andw $0x3fff, %bx; orw $0xc000, %bx`).
            if word & 0xC000 == 0xC000 { return .constant(word & 0x3FFF) }
            return .terminal(umisteni: UInt8(word >> 8), svorka: UInt8(word & 0xFF))
        }
    }

    /// One row of Dirigo's symbol table, with the fields the record's words are built from.
    public struct Symbol: Equatable, Sendable {
        public var id: Int
        public var owner: Int
        public var driver: Int
        public var type: Int              // 4 = a module's own variable row, 6 = a pin row
        public var index: Int
        public var rowIndex: Int
        public var colIndex: Int
        public var name: String
        public var umisteni: Int
        public var svorka: Int
        /// The columns the compiler does not read but the file carries. All five real symbol tables hold
        /// them constant or empty (`POPIS`/`DATA` empty, `K` 1, `Q` 0, `RIGHTS` 2, `INFO1-3`, `K_ADR`,
        /// `Q_ADR` empty), so they are defaults rather than parsed state. `data`/`k`/`q` are text because
        /// that is what the file has: the DBF behind it types them as *doubles* and prints them as such.
        public var popis: String = ""
        public var data: String = ""
        public var k: String = "1"
        public var q: String = "0"
        public var rights: Int = 2
        public var info1: String = ""
        public var info2: String = ""
        public var info3: String = ""
        public var kAdr: String = ""
        public var qAdr: String = ""

        public init(id: Int, owner: Int, driver: Int = 20, type: Int, index: Int, rowIndex: Int,
                    colIndex: Int, name: String, umisteni: Int, svorka: Int, popis: String = "",
                    data: String = "", k: String = "1", q: String = "0", rights: Int = 2,
                    info1: String = "", info2: String = "", info3: String = "",
                    kAdr: String = "", qAdr: String = "") {
            self.id = id; self.owner = owner; self.driver = driver; self.type = type
            self.index = index; self.rowIndex = rowIndex; self.colIndex = colIndex; self.name = name
            self.umisteni = umisteni; self.svorka = svorka
            self.popis = popis; self.data = data; self.k = k; self.q = q; self.rights = rights
            self.info1 = info1; self.info2 = info2; self.info3 = info3
            self.kAdr = kAdr; self.qAdr = qAdr
        }

        /// `500 + umisteni` then the terminal, or `1000 + umisteni*100` then the terminal, with the
        /// terminal 1-based — the scheme the rows' own ids use (`500601` = module 6, terminal 1).
        public var terminalWord: UInt16 { UInt16(umisteni << 8) | UInt16(svorka) }
        public var slotWord: UInt16? { type == 4 ? 0x1000 + UInt16(rowIndex) : nil }
    }

    /// The column order of the file, exactly as Dirigo's own header has it. The reader and the writer
    /// both take their order from here, so they cannot drift apart.
    public static let symbolColumns = ["ID", "OWNER", "DRIVER", "TYP", "INDEX", "ROWINDEX", "COLINDEX",
                                       "NAME", "POPIS", "DATA", "K", "Q", "RIGHTS", "UMISTENI", "SVORKA",
                                       "INFO1", "INFO2", "INFO3", "K_ADR", "Q_ADR"]

    /// The symbol table as Dirigo writes it.
    ///
    /// CRLF lines, a fully quoted header, and the quoting of each row following the **DBF field type**
    /// behind it — character columns quoted, integer and double columns bare. That is why `UMISTENI` and
    /// `SVORKA` are `"1"`/`"0"` while `INDEX`/`ROWINDEX` are bare, and why an empty `DATA` is nothing at
    /// all where an empty `POPIS` is `""`. `TDBFTable` (Dbftable) types the columns as
    /// `I I I I I I I C C O O O I C C C C C I I`, which is where the pattern comes from.
    ///
    /// Verified by round trip against all five real symbol tables (`SymbolTableTests.roundTrip`).
    public static func csv(fromSymbols rows: [Symbol]) -> String {
        var out = symbolColumns.map { "\"\($0)\"" }.joined(separator: ",") + "\r\n"
        for r in rows {
            let fields: [String] = [
                "\(r.id)", "\(r.owner)", "\(r.driver)", "\(r.type)", "\(r.index)", "\(r.rowIndex)",
                "\(r.colIndex)",
                "\"\(r.name)\"",
                "\"\(r.popis)\"",
                r.data,                                   // DBF double: bare, empty when unset
                r.k, r.q,
                "\(r.rights)",
                "\"\(r.umisteni)\"", "\"\(r.svorka)\"",   // DBF character columns
                "\"\(r.info1)\"", "\"\(r.info2)\"", "\"\(r.info3)\"",
                r.kAdr, r.qAdr,
            ]
            out += fields.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// The whole symbol table, not just the slots. Columns are positional, from `symbolColumns`.
    public static func symbols(fromSymbolCSV csv: String) -> [Symbol] {
        csv.components(separatedBy: "\n").dropFirst().compactMap { rawLine in
            // The file is CRLF; the final field would otherwise keep the carriage return, and the
            // writer would emit it twice.
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let f = line.components(separatedBy: ",")
            guard f.count >= 20 else { return nil }
            guard let id = Int(clean(f[0])), let owner = Int(clean(f[1])),
                  let driver = Int(clean(f[2])), let type = Int(clean(f[3])),
                  let index = Int(clean(f[4])), let row = Int(clean(f[5])),
                  let col = Int(clean(f[6])), let rights = Int(clean(f[12])),
                  let umisteni = Int(clean(f[13])), let svorka = Int(clean(f[14])) else { return nil }
            return Symbol(id: id, owner: owner, driver: driver, type: type, index: index,
                          rowIndex: row, colIndex: col, name: clean(f[7]),
                          umisteni: umisteni, svorka: svorka,
                          popis: clean(f[8]), data: clean(f[9]), k: clean(f[10]).isEmpty ? "0" : clean(f[10]),
                          q: clean(f[11]).isEmpty ? "0" : clean(f[11]), rights: rights,
                          info1: clean(f[15]), info2: clean(f[16]), info3: clean(f[17]),
                          kAdr: clean(f[18]), qAdr: clean(f[19]))
        }
    }

    // MARK: - The symbol table

    /// Data-slot indices, from the symbol table Dirigo writes beside a project (`had.csv`).
    ///
    /// A module's slot is `0x1000 + ROWINDEX` of its own output symbol: a `TYP=4` row whose `NAME`
    /// contains a dot — `Counter1.Y`, `PulseGen1.Cnt`, `ISwitch1.Y`, `SystemCmd1.Out`. Verified against
    /// `had+1block.csv` on all four modules in `had.pcc` that have such a row. `Comparator1` has none and
    /// `ISwitch1` carries two slots against its one row, so this is a lower bound, not the whole rule.
    ///
    /// The file is CRLF, comma-separated, with every field quoted. Columns are positional:
    /// `ID, OWNER, DRIVER, TYP, INDEX, ROWINDEX, COLINDEX, NAME, …`.
    public static func slots(fromSymbolCSV csv: String) -> [String: UInt16] {
        var out: [String: UInt16] = [:]
        for s in symbols(fromSymbolCSV: csv) where s.type == 4 {
            guard let dot = s.name.firstIndex(of: ".") else { continue }
            out[String(s.name[..<dot])] = UInt16(s.rowIndex)
        }
        return out
    }

    /// Strips the quotes Dirigo wraps every field in, and any CR left by the file's CRLF endings.
    private static func clean(_ field: String) -> String {
        field.replacingOccurrences(of: "\"", with: "")
             .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Small XML helpers

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attribute(_ name: String, _ tag: String) -> String? {
        matches("\\b\(name)=\"([^\"]*)\"", in: tag).first
            .flatMap { matches("\"([^\"]*)\"", in: $0).first }
            .map { String($0.dropFirst().dropLast()) }
    }

    /// The element body following a start tag, up to its matching close — good enough for this file.
    private static func body(of tag: String, in xml: String) -> String {
        guard let start = xml.range(of: tag) else { return "" }
        let rest = xml[start.upperBound...]
        let element = matches(#"<MODULE\b"#, in: tag).isEmpty ? "" : "MODULE"
        guard !element.isEmpty, let end = rest.range(of: "</\(element)>") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }
}
