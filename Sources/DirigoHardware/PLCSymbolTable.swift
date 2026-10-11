import Foundation

/// The per-class out-pin table, and the allocation that turns a project into Dirigo's symbol table.
///
/// Every entry here is *derived from Dirigo's own symbol tables* (the `.csv` rows themselves), not from a
/// reading of the decompiler: `docs/class-pins.json` records which rows each class produced in which
/// project. The allocation rules below are the ones those files show.
///
/// The shape of the thing, as the artefacts give it:
///
/// * a module's **own value** is a word — the "module row", named after the module when its pin has no
///   name (`PulseGen1`) and after the pin when it has one (`ISwitch1.Y`). `PulseGen1`'s is at `SVORKA` 1,
///   `8xDI1`'s at 0;
/// * a **word** out-pin (`PulseGen1.Cnt`, `Counter1.Y`, `SystemCmd1.Out`) gets an index in the same int
///   array as the module values;
/// * a **Boolean** out-pin gets a bit index, and its record word is `(bit << 8) | container`, where the
///   container is 0 for an ordinary Boolean and the word's slot for a *bit of a word* — which is why
///   `Int2Bits`' `B0..B15` and `8xDI`'s `DI0..DI7` number from 0 inside their own block;
/// * **two passes**, both in ascending module `ID`: the module values first, then the pins. That is what
///   makes `kostička`'s indices `PulseGen1` 0, `ISwitch1.Y` 1, `8xDI1` 2, `PulseGen1.Cnt` 3,
///   `Counter1.Y` 4, `SystemCmd1.Out` 5 — and it reproduces `had.csv` exactly as well.
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
                    words: [Int: String] = [:], bools: [Int: String] = [:],
                    unexportedBools: [Int] = [],
                    localBitSvorka: Int? = nil, localBits: [String] = [],
                    fixedWidth: Int? = nil, localBitsAreUnexported: Bool = false) {
            self.moduleValue = moduleValue; self.moduleValuePin = moduleValuePin
            self.words = words; self.bools = bools; self.unexportedBools = unexportedBools
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
        /// The record word this pin contributes: `(index << 8) | rowIndex`, or `0x1000 + rowIndex`.
        public var word: UInt16 {
            isBoolean ? UInt16(index << 8) | UInt16(rowIndex) : 0x1000 + UInt16(rowIndex)
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

    public init(modules: [PLCProjectCompiler.Module], wires: [PLCProjectCompiler.Wire],
                classForGUID: [String: String], shapes: [String: PLCProjectCompiler.ClassShape]) {
        // Ascending module ID — the order both passes run in, and the order the file's rows are in.
        let sorted = modules.sorted { ($0.umisteni, $0.order) < ($1.umisteni, $1.order) }
        for m in modules { modulesByID[m.umisteni] = m.name }
        func spec(_ m: PLCProjectCompiler.Module) -> PLCClassPins.Spec? {
            let cls = classForGUID[PLCProjectCompiler.normaliseGUID(m.guid)] ?? classForGUID[m.guid]
            return cls.flatMap { PLCClassPins.all[$0] }
        }
        // The wire that feeds a module's input pin, by (module, in-pin).
        var feeds: [UInt8: [Int: (module: UInt8, pin: Int)]] = [:]
        for w in wires { feeds[w.inModule, default: [:]][w.inPin] = (w.outModule, w.outPin) }

        // MARK: pass A — the module values, then pass B — the pins, both in ascending module ID

        var nextWord = 0
        var nextBit = 0
        var moduleRowID: [UInt8: Int] = [:]
        var moduleRowName: [UInt8: String] = [:]

        for m in sorted {
            guard let s = spec(m) else { continue }
            if let sv = s.moduleValue {
                let id = 1000 + Int(m.umisteni) * 100 + sv + 1
                let name = s.moduleValuePin.map { "\(m.name).\($0)" } ?? m.name
                moduleWord[m.umisteni] = nextWord
                moduleSlot[m.umisteni] = nextWord
                moduleRowID[m.umisteni] = id
                moduleRowName[m.umisteni] = name
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: nextWord, rowIndex: nextWord, isBoolean: false)
                rows.append(Row(id: id, owner: -1, type: 4, index: 510, rowIndex: nextWord,
                                colIndex: 0, name: name, umisteni: Int(m.umisteni), svorka: sv))
                nextWord += 1
            }
        }

        var pinRows: [Row] = []
        for m in sorted {
            guard let s = spec(m) else { continue }
            // Word out-pins. The first one *is* the module's slot when the record refers to it.
            var hasWordPin = false
            for (sv, name) in s.words.sorted(by: { $0.key < $1.key }) {
                let index = nextWord
                nextWord += 1
                if !hasWordPin { moduleSlot[m.umisteni] = index; hasWordPin = true }
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: index, rowIndex: index, isBoolean: false)
                // A class whose own value is this pin has no separate module row: its row *is* this one,
                // named after the module, and it is the row the other pins own.
                let name = "\(m.name).\(name)"
                pinRows.append(Row(id: 1000 + Int(m.umisteni) * 100 + sv + 1, owner: -1, type: 4,
                                   index: 510, rowIndex: index, colIndex: 0, name: name,
                                   umisteni: Int(m.umisteni), svorka: sv))
            }
            // Block-local bits: indexed from 0 inside the block, in a container word.
            if let sv = s.localBitSvorka {
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
                let names = s.localBits.isEmpty ? (0..<width).map { "\(s.localBitSvorka == 0 ? "B" : "B")\($0)" }
                                                : Array(s.localBits.prefix(width))
                if !s.localBitsAreUnexported {
                    for (i, name) in names.enumerated() {
                        // A block-local bit's `SVORKA` is its own index in the out-pin list (`B0`..`B15`
                        // are 0..15), not the run's base — keying them all under `sv` would leave the
                        // wires that read them unable to resolve.
                        addresses[UInt16(m.umisteni) << 8 | UInt16(i)] =
                            PinAddress(index: i, rowIndex: container, isBoolean: true)
                        pinRows.append(Row(id: 500000 + Int(m.umisteni) * 100 + i + 1, owner: -1,
                                           type: 6, index: i, rowIndex: container, colIndex: 0,
                                           name: "\(m.name).\(name)", umisteni: Int(m.umisteni),
                                           svorka: i))
                    }
                } else {
                    for i in 0..<width {
                        addresses[UInt16(m.umisteni) << 8 | UInt16(i)] =
                            PinAddress(index: i, rowIndex: container, isBoolean: true)
                    }
                }
            }
            // Ordinary Boolean out-pins: a bit each, container 0. The unexported ones take a bit and
            // write no row, which is where the holes in the bit numbering come from.
            for sv in s.unexportedBools.sorted() {
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: nextBit, rowIndex: 0, isBoolean: true)
                nextBit += 1
            }
            for (sv, name) in s.bools.sorted(by: { $0.key < $1.key }) {
                let bit = nextBit
                nextBit += 1
                addresses[UInt16(m.umisteni) << 8 | UInt16(sv)] =
                    PinAddress(index: bit, rowIndex: 0, isBoolean: true)
                pinRows.append(Row(id: 500000 + Int(m.umisteni) * 100 + sv + 1, owner: -1, type: 6,
                                   index: bit, rowIndex: 0, colIndex: 0,
                                   name: "\(m.name).\(name)", umisteni: Int(m.umisteni), svorka: sv))
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
        addresses[UInt16(w.outModule) << 8 | UInt16(w.outPin)]?.word
    }
}
