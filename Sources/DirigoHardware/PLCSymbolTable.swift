import Foundation

/// The per-class out-pin table, and the allocation that turns a project into Dirigo's symbol table.
///
/// Every entry here is *derived from Dirigo's own symbol tables* (the `.csv` rows themselves), not from a
/// reading of the decompiler: `docs/class-pins.json` records which rows each class produced in which
/// project. The allocation rules below are the ones those files show.
///
/// The shape of the thing, as the artefacts give it:
///
/// * a module's **own value** is a word (`ISwitch1.Y`, `8xDI1`) or, for a class whose value is one of its
///   Booleans (`And`, `PulseGen`), the row of that bit;
/// * a **word** out-pin (`PulseGen1.Cnt`, `Counter1.Y`, `SystemCmd1.Out`) takes a word row;
/// * a **Boolean** out-pin takes a bit, and its record word is `(bit << 8) | row`; `Int2Bits`' `B0..B15` and
///   `8xDI`'s `DI0..DI7` are bits *of* a word row, numbered from 0 inside their block;
/// * bits and words share one array, first-fit (`AllocFreeBit` / `AllocFreeInt`), in **expansion order**
///   (`PLCProjectCompiler.expansionOrder`): first each module's bits where it stands, a digital input's
///   own word and the word an `Int2Bits` splits; then every other word. That reproduces every
///   INDEX and ROWINDEX of the captured `rulkoshaddirigo` saves (`docs/plc-protocol.md`).
public enum PLCClassPins {
    /// What a class registers, as its rows show it.
    public struct Spec: Sendable, Equatable {
        /// `SVORKA` of the module's own value, if the class has one: pass A allocates it.
        public var moduleValue: Int?
        /// The name of the pin the module value is read from, if it has one: `ISwitch1`'s own value is
        /// its `Y`, so its row is `ISwitch1.Y` rather than `ISwitch1`.
        public var moduleValuePin: String?
        /// Word out-pins: `SVORKA` to pin name. Pass B allocates them in the int array.
        public var words: [Int: String]
        /// Long out-pins: `SVORKA` to pin name. They take an index in the long array, a `0x2000` slot.
        public var longs: [Int: String]
        /// Ordinary Boolean out-pins: `SVORKA` to pin name. Pass B allocates them a bit.
        public var bools: [Int: String]
        /// `SVORKA` of a run of block-local bits (`Int2Bits`, `8xDI`): `B0..B15`, `DI0..DI7`. They are
        /// indexed from 0 inside the block and live in a container word.
        public var localBitSvorka: Int?
        public var localBits: [String]
        /// Boolean out-pins that are *allocated but not written to the file* — `TMCounter`'s Boolean out
        /// at `SVORKA` 0, which takes bit 2 in `had.pcc` between `zapnuti.Y` and `reset.Y` without
        /// producing a row of its own.
        public var unexportedBools: [Int]
        /// Block-local bits are indexed from 0 and *counted from the project*: `Int2Bits1` has six in
        /// `had.pcc` and `Int2Bits3` has eight in `kostička`, and the file has exactly that many rows.
        /// `fixedWidth` overrides that for blocks whose width is their own (`8xDI` is always 8).
        public var fixedWidth: Int?
        /// Write no rows for the local bits (`8xDO`): they take channels but are not in the file.
        public var localBitsAreUnexported: Bool

        public init(moduleValue: Int? = nil, moduleValuePin: String? = nil,
                    words: [Int: String] = [:], longs: [Int: String] = [:], bools: [Int: String] = [:],
                    unexportedBools: [Int] = [],
                    localBitSvorka: Int? = nil, localBits: [String] = [],
                    fixedWidth: Int? = nil, localBitsAreUnexported: Bool = false) {
            self.moduleValue = moduleValue; self.moduleValuePin = moduleValuePin
            self.words = words; self.longs = longs; self.bools = bools; self.unexportedBools = unexportedBools
            self.localBitSvorka = localBitSvorka; self.localBits = localBits
            self.fixedWidth = fixedWidth; self.localBitsAreUnexported = localBitsAreUnexported
        }
    }

    /// The classes the corpus fixes. Each name and index here appears in a real `.csv`.
    public static let all: [String: Spec] = [
        // PulseGen1: Cnt (word, SVORKA 0), its own value + Out (Bool, SVORKA 1).
        "TMPulseGenerator": Spec(moduleValue: 1, words: [0: "Cnt"], bools: [1: "Out"]),
        // ISwitch1: its own value *is* its named word pin, so the row is `ISwitch1.Y` at SVORKA 0.
        "TMIntSwitch": Spec(moduleValue: 0, moduleValuePin: "Y"),
        // 8xDI1: its own word at SVORKA 0, then eight block-local bits (its width is its own).
        "TMDigitalInputs": Spec(moduleValue: 0, localBitSvorka: 0,
                                localBits: (0..<8).map { "DI\($0)" }, fixedWidth: 8),
        // Int2Bits: block-local bits whose container is the word they split; the count is the project's.
        "TMInt2Bits": Spec(localBitSvorka: 0, localBits: []),
        // Counter1 has a Boolean out at SVORKA 0 that is allocated and not written.
        "TMCounter": Spec(words: [1: "Y"], unexportedBools: [0]),
        "TMComparator": Spec(bools: [0: "AGtB", 1: "AEqB", 2: "ALtB"]),
        // AdvCounter: Y is the module's own word value (P1 registers only H and L, with `getter: own` for Y),
        // H and L are Booleans, and the hidden Boolean that holds the previous Tr is allocated first, as the
        // captured records show (`0x0204`, `0x0304`, `0x0404` in `*had`).
        "TMAdvCounter": Spec(moduleValue: 0, bools: [1: "H", 2: "L"], unexportedBools: [3]),
        // Div: out-pin 0 is the quotient, a Long (`0x2000 + index`); out-pin 1 is the int remainder.
        "TMDiv": Spec(moduleValue: 1, longs: [0: "Y"]),
        "TMOr": Spec(bools: [0: "Y"]),
        "TMNot": Spec(bools: [0: "Y"]),
        "TMBoolVar": Spec(bools: [0: "Y"]),
        "TSystemCommand": Spec(words: [0: "Out"]),
        "TMEquitherm": Spec(words: [0: "WT"]),
        "TMAnd": Spec(moduleValue: 0, bools: [0: "Y"]),
        // 8xDO takes eight channels but writes no rows in any symbol table we have.
        "TMDigitalOutputs": Spec(localBitSvorka: 0, fixedWidth: 8, localBitsAreUnexported: true),
    ]
}

/// Generates Dirigo's symbol table for a project.
///
/// The compiler needs two things from that table — each module's word slot and each pin's
/// `(INDEX, ROWINDEX)` — and they are the same two numbers the program table's record words are built
/// from. So this is not a report: it is the allocation the records come from.
public struct PLCSymbolTable: Sendable {
    /// One generated row, before it becomes CSV text.
    public typealias Row = PLCProjectCompiler.Symbol

    /// A pin's allocated address, keyed by `(module, svorka)`.
    public struct PinAddress: Equatable, Sendable {
        /// `INDEX`: the bit index for a Boolean, the int-array index for a word.
        public var index: Int
        /// `ROWINDEX`: the container word for a bit, the int-array index for a word.
        public var rowIndex: Int
        public var isBoolean: Bool
        /// A Long: an index in the long array, whose record word is `0x2000 + index`.
        public var isLong: Bool = false
        /// The record word this pin contributes: `(index << 8) | rowIndex`, `0x1000 + rowIndex`, or
        /// `0x2000 + index` for a Long.
        public var word: UInt16 {
            if isLong { return 0x2000 + UInt16(rowIndex) }
            return isBoolean ? UInt16(index << 8) | UInt16(rowIndex) : 0x1000 + UInt16(rowIndex)
        }
    }

    public private(set) var rows: [Row] = []
    /// `(module id, svorka) -> the pin's address`. The program table's wires resolve through this.
    public private(set) var addresses: [UInt16: PinAddress] = [:]
    /// The module's own word slot, by module id — `0x1000 + this` is the module's output value.
    public private(set) var moduleWord: [UInt8: Int] = [:]
    /// Module names by id, so a caller can name an allocation rather than number it.
    public private(set) var modulesByID: [UInt8: String] = [:]
    /// The index a module's `.slot` role refers to: its first word out-pin, or its own value when it has
    /// no separate word pin.
    public private(set) var moduleSlot: [UInt8: Int] = [:]
    /// Registered-but-unwritten Boolean out-pins by module, which the file's pin numbering skips.
    private var unexportedByModule: [UInt8: [Int]] = [:]

    /// The registration index (`SVORKA`) of a file out pin: the file's pins are the registered ones minus
    /// the unexported, in order.
    private func registrationPin(_ module: UInt8, _ filePin: Int) -> Int {
        var index = filePin
        for u in unexportedByModule[module] ?? [] where u <= index { index += 1 }
        return index
    }

    public init(modules: [PLCProjectCompiler.Module], wires: [PLCProjectCompiler.Wire],
                classForGUID: [String: String], shapes: [String: PLCProjectCompiler.ClassShape]) {
        // Ascending module ID — the order both passes run in, and the order the file's rows are in.
        let sorted = modules.sorted { ($0.umisteni, $0.order) < ($1.umisteni, $1.order) }
        for m in modules { modulesByID[m.umisteni] = m.name }
        func spec(_ m: PLCProjectCompiler.Module) -> PLCClassPins.Spec? {
            let cls = classForGUID[PLCProjectCompiler.normaliseGUID(m.guid)] ?? classForGUID[m.guid]
            return cls.flatMap { PLCClassPins.all[$0] }
        }
        // A wire names the *file's* out pin, which skips the pins a class registers but does not write
        // (`TMCounter`'s hidden Boolean at registration 0, so its `Y` is file pin 0 and registration 1).
        for m in modules { if let s = spec(m), !s.unexportedBools.isEmpty { unexportedByModule[m.umisteni] = s.unexportedBools.sorted() } }
        // The wire that feeds a module's input pin, by (module, in-pin).
        var feeds: [UInt8: [Int: (module: UInt8, pin: Int)]] = [:]
        for w in wires {
            feeds[w.inModule, default: [:]][w.inPin] = (w.outModule, registrationPin(w.outModule, w.outPin))
        }

        // MARK: allocation — one array of 16-bit cells, first-fit, in Dirigo's expansion order
        //
        // Dirigo's `TDataArrays` (PccBase.bpl) holds bits and words in the *same* array: `AllocFreeBit` (0x47E6C8)
        // takes the lowest clear bit of the first row that is not 0xFFFF, and `AllocFreeInt` (0x47E824) takes the
        // first row that is 0 and sets it to 0xFFFF — so a row holding any bit is never a word. The captured
        // `rulkoshaddirigo` table fixes the order (docs/plc-protocol.md, "Captured records decoded"):
        //   1. in expansion order, each module takes its Boolean bits where it stands; a digital input takes its
        //      own word; an Int2Bits takes the word of the module it reads (`TMInt2Bits.ExportFile` calls
        //      `AllocFreeInt`);
        //   2. then every other word is taken in expansion order.
        var cells: [UInt16] = []
        func allocateBit() -> (bit: Int, row: Int) {
            var row = 0
            while true {
                while cells.count <= row { cells.append(0) }
                if cells[row] != 0xFFFF {
                    for bit in 0..<16 where cells[row] & (1 << bit) == 0 {
                        cells[row] |= 1 << bit
                        return (bit, row)
                    }
                }
                row += 1
            }
        }
        func allocateWord() -> Int {
            var row = 0
            while true {
                while cells.count <= row { cells.append(0) }
                if cells[row] == 0 {
                    cells[row] = 0xFFFF
                    return row
                }
                row += 1
            }
        }
        var moduleRowID: [UInt8: Int] = [:]
        var moduleRowName: [UInt8: String] = [:]
        var pinRows: [Row] = []
        var wordsPlaced: Set<UInt8> = []
        var nextLong = 0
        var byID: [UInt8: PLCProjectCompiler.Module] = [:]
        for m in modules { byID[m.umisteni] = m }

        func placeBools(_ m: PLCProjectCompiler.Module, _ s: PLCClassPins.Spec) {
            // The unexported ones take a bit and write no row, which is where the holes in the numbering come from.
            for sv in s.unexportedBools.sorted() {
                let allocated = allocateBit()
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: allocated.bit, rowIndex: allocated.row, isBoolean: true)
            }
            for (sv, name) in s.bools.sorted(by: { $0.key < $1.key }) {
                let allocated = allocateBit()
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: allocated.bit, rowIndex: allocated.row, isBoolean: true)
                pinRows.append(Row(id: 500000 + Int(m.umisteni) * 100 + sv + 1, owner: -1, type: 6,
                                   index: allocated.bit, rowIndex: allocated.row, colIndex: 0,
                                   name: "\(m.name).\(name)", umisteni: Int(m.umisteni), svorka: sv))
            }
            // A class whose own value is one of its Booleans (`And`, `PulseGen`) has its module row where that bit is.
            if let sv = s.moduleValue, let a = addresses[UInt16(m.umisteni) << 8 | UInt16(sv)], a.isBoolean {
                let id = 1000 + Int(m.umisteni) * 100 + sv + 1
                moduleRowID[m.umisteni] = id
                moduleRowName[m.umisteni] = m.name
                rows.append(Row(id: id, owner: -1, type: 4, index: 510, rowIndex: a.rowIndex,
                                colIndex: 0, name: m.name, umisteni: Int(m.umisteni), svorka: sv))
            }
        }

        func placeWords(_ m: PLCProjectCompiler.Module, _ s: PLCClassPins.Spec) {
            guard wordsPlaced.insert(m.umisteni).inserted else { return }
            if let sv = s.moduleValue, s.bools[sv] == nil {
                let id = 1000 + Int(m.umisteni) * 100 + sv + 1
                let name = s.moduleValuePin.map { "\(m.name).\($0)" } ?? m.name
                let index = allocateWord()
                moduleWord[m.umisteni] = index
                moduleSlot[m.umisteni] = index
                moduleRowID[m.umisteni] = id
                moduleRowName[m.umisteni] = name
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: index, rowIndex: index, isBoolean: false)
                rows.append(Row(id: id, owner: -1, type: 4, index: 510, rowIndex: index,
                                colIndex: 0, name: name, umisteni: Int(m.umisteni), svorka: sv))
            }
            for (sv, _) in s.longs.sorted(by: { $0.key < $1.key }) {
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: nextLong, rowIndex: nextLong, isBoolean: false, isLong: true)
                nextLong += 1
            }
            // Word out-pins. The first one *is* the module's slot when the record refers to it.
            var hasWordPin = false
            for (sv, name) in s.words.sorted(by: { $0.key < $1.key }) {
                let index = allocateWord()
                if !hasWordPin { moduleSlot[m.umisteni] = index; hasWordPin = true }
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: index, rowIndex: index, isBoolean: false)
                pinRows.append(Row(id: 1000 + Int(m.umisteni) * 100 + sv + 1, owner: -1, type: 4,
                                   index: 510, rowIndex: index, colIndex: 0, name: "\(m.name).\(name)",
                                   umisteni: Int(m.umisteni), svorka: sv))
            }
        }

        let expansion = PLCProjectCompiler.expansionOrder(modules)
        for m in expansion {
            guard let s = spec(m) else { continue }
            placeBools(m, s)
            if s.localBitSvorka != nil, !s.localBitsAreUnexported {
                if s.moduleValue != nil {
                    placeWords(m, s)                       // 8xDI: its own word
                } else if let src = feeds[m.umisteni]?.keys.sorted().first.flatMap({ feeds[m.umisteni]?[$0] }),
                          let sm = byID[src.module], let ss = spec(sm) {
                    placeWords(sm, ss)                     // Int2Bits: the word it splits
                }
            }
        }
        for m in expansion {
            guard let s = spec(m) else { continue }
            placeWords(m, s)
        }

        // Block-local bits: indexed from 0 inside the block, in a container word.
        for m in sorted {
            guard let s = spec(m), s.localBitSvorka != nil else { continue }
            let container: Int
            if let own = moduleWord[m.umisteni] {
                container = own
            } else if let src = feeds[m.umisteni]?.keys.sorted().first
                            .flatMap({ feeds[m.umisteni]?[$0] }),
                      let a = addresses[key(src)] {
                container = a.rowIndex
            } else {
                container = 0
            }
            let width = s.fixedWidth ?? (s.localBitsAreUnexported ? 0 : m.outPinCount)
            // A block with a `PIN_MASK` has a pin for each set bit only (`8xDI1` `$0030`: `DI4`, `DI5`); the
            // file's out-pin `k` is the `k`-th set bit, and the row's INDEX is that channel number.
            var channels = Array(0..<width)
            if let mask = m.pinMask, !s.localBitsAreUnexported {
                channels = (0..<16).filter { mask & (1 << $0) != 0 }
            }
            if !s.localBitsAreUnexported {
                for (k, channel) in channels.enumerated() {
                    let label = channel < s.localBits.count ? s.localBits[channel] : "B\(channel)"
                    addresses[UInt16(m.umisteni) << 8 | UInt16(k)] =
                        PinAddress(index: channel, rowIndex: container, isBoolean: true)
                    pinRows.append(Row(id: 500000 + Int(m.umisteni) * 100 + k + 1, owner: -1,
                                       type: 6, index: channel, rowIndex: container, colIndex: 0,
                                       name: "\(m.name).\(label)", umisteni: Int(m.umisteni),
                                       svorka: k))
                }
            } else {
                for i in 0..<width {
                    addresses[UInt16(m.umisteni) << 8 | UInt16(i)] =
                        PinAddress(index: i, rowIndex: container, isBoolean: true)
                }
            }
        }

        // MARK: OWNER — the word row of the value the pin carries, else the first module row

        // `had.csv` and `kostička.csv` together fix this: a Boolean pin is owned by its *own* module's
        // value when that module has one (`8xDI1.DI0` → `2001`, `PulseGen1.Out` → `1102`); otherwise by
        // the value of the module it reads — but only when what it reads *is* that module's own value
        // (`Int2Bits1.B0` reads `ISwitch1.Y`, which is `ISwitch1`'s own value, so → `1501`); and
        // otherwise by the first module row in the project (`Or1.Y` → `1102`), which is why that odd
        // default shows up on both files.
        let defaultOwner = moduleRowID.keys.sorted().first.flatMap { moduleRowID[$0] }
        var ownValuePin: [UInt8: Int] = [:]
        for m in sorted {
            if let s = spec(m), let sv = s.moduleValue { ownValuePin[m.umisteni] = sv }
        }
        func ownerFor(_ m: PLCProjectCompiler.Module) -> Int {
            if let own = moduleRowID[m.umisteni] { return own }
            var seen: Set<UInt8> = []
            var current = m.umisteni
            while let source = feeds[current]?.sorted(by: { $0.key < $1.key })
                                        .first(where: { !seen.contains($0.value.module) })?.value {
                seen.insert(source.module)
                if ownValuePin[source.module] == source.pin, let id = moduleRowID[source.module] {
                    return id
                }
                current = source.module
            }
            return defaultOwner ?? -1
        }

        // The rows are *written* in the project's own module order — the order of the `<MODULE>` elements
        // — while the allocation above ran in ascending module ID. `kostička.pcc` has `ISwitch1` first in
        // the file, and `kostička.csv` starts with `ISwitch1.Y` even though `ISwitch1` is module 5 and its
        // index (1) is the second allocated; `had.pcc` is in id order in the file, so the two agree there.
        var ordered: [Row] = []
        for m in modules.sorted(by: { $0.fileIndex < $1.fileIndex }) {
            var mine = rows.filter { $0.umisteni == Int(m.umisteni) }
            mine += pinRows.filter { $0.umisteni == Int(m.umisteni) }
            mine.sort { a, b in
                if a.svorka != b.svorka { return a.svorka < b.svorka }
                // The module row (the bare module name) comes before the named pin at the same svorka.
                return a.name.count < b.name.count
            }
            for var r in mine {
                if r.type == 6 { r.owner = ownerFor(m) }
                ordered.append(r)
            }
        }
        self.rows = ordered
    }

    private func key(_ p: (module: UInt8, pin: Int)) -> UInt16 {
        UInt16(p.module) << 8 | UInt16(p.pin)
    }

    public var csv: String { PLCProjectCompiler.csv(fromSymbols: rows) }

    /// Module name to the index of the word its record's `.slot` role refers to — the module's first word
    /// out-pin (`PulseGen1` → `Cnt`), or its own value when the class has no separate word pin
    /// (`ISwitch1` → its `Y`). This is what a supplied `.csv`'s `ROWINDEX` column used to provide.
    public var slots: [String: UInt16] {
        var out: [String: UInt16] = [:]
        for (id, index) in moduleSlot {
            if let name = modulesByID[id] { out[name] = UInt16(index) }
        }
        return out
    }

    /// The value a wire contributes to the record it lands in: the source pin's own address.
    public func value(fromWire w: PLCProjectCompiler.Wire) -> UInt16? {
        addresses[UInt16(w.outModule) << 8 | UInt16(registrationPin(w.outModule, w.outPin))]?.word
    }
}
