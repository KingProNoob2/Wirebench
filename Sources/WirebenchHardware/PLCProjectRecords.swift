import Foundation

extension PLCProjectCompiler {
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
        var starts: [Int: Int] = [:]
        return try records(modules: modules, wires: wires, slots: slots, wireValue: { $0.value },
                           allocation: allocation, threadStarts: &starts)
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
        var starts: [Int: Int] = [:]
        return try records(modules: modules, wires: wires, slots: allocation.slots,
                           wireValue: { allocation.value(fromWire: $0) ?? PLCProgramBuilder.Module.constant(0) },
                           allocation: allocation, threadStarts: &starts)
    }

    /// Records with the offset each thread's first record sits at.
    private func records(modules: [Module], wires: [Wire], slots: [String: UInt16],
                         wireValue: (Wire) -> UInt16,
                         allocation: PLCSymbolTable? = nil,
                         threadStarts: inout [Int: Int]) throws -> [UInt8] {
        // A module's word is looked up by its id when the slots are the allocation's own: the modules of a macro's sheet are copied
        // per call and keep their names, so by name two copies would read one slot. Slots a caller supplied stay by name.
        let slotsAreAllocated = allocation.map { $0.slots == slots } ?? false
        func slotWord(_ m: Module) -> UInt16? {
            if slotsAreAllocated, let index = allocation?.moduleSlot[m.umisteni] { return UInt16(index) }
            return slots[m.name]
        }
        var byInput: [UInt8: [Int: UInt16]] = [:]
        for w in wires {
            // A parameter wire is keyed past the in-pins, so the two never share a slot.
            byInput[w.inModule, default: [:]][w.isParam ? Self.paramKeyBase + w.inPin : w.inPin] = wireValue(w)
        }

        var out: [UInt8] = []
        var lastThread: Int?
        for m in modules {
            // Brace-insensitive: the project writes `{ABC}`, the id table stores `ABC`.
            let cls = classForGUID[Self.normaliseGUID(m.guid)] ?? classForGUID[m.guid] ?? "?"
            guard let shape = shapes[cls] else { continue }
            guard shape.contributesRecord else { continue }
            // A thread's records start on a 64-byte boundary of the record region: the capture has thread 2's
            // twelve bytes, 52 zeros, then thread 4 at 0x80.
            if let last = lastThread, last != m.threadId, out.count % 64 != 0 {
                out.append(contentsOf: [UInt8](repeating: 0, count: 64 - out.count % 64))
            }
            lastThread = m.threadId
            if threadStarts[m.threadId] == nil { threadStarts[m.threadId] = out.count }
            // The record's second byte is not a flag of the program's: it is the OR of the hidden
            // in-pins' `pin[0x70]` values (`InPinToStream`, P1.bpl 0x40DE0E), so it comes out of the
            // class's own shape before any word is written.
            let feeds = byInput[m.umisteni] ?? [:]
            let longSwitch = Self.isLongSwitch(cls: cls, inPinCount: m.inPinCount)
            let flag = Self.recordFlag(for: m, cls: cls, shape: shape, feeds: feeds, longSwitch: longSwitch)
            out.append(shape.id ?? 0)
            out.append(flag)
            func put(_ value: UInt16) {
                out.append(UInt8(truncatingIfNeeded: value))
                out.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            // The first in-pin is a word only when it is wired; unwired it is the flag bit above.
            let readsInPinZero = shape.roles.contains { role in
                switch role {
                case .inPin(0), .inPinOrConstant(0), .inPinOrValue(0): return true
                default: return false
                }
            }
            if !readsInPinZero, let wired = feeds[0] { put(wired) }
            func inValue(_ i: Int) -> UInt16 {
                feeds[i] ?? PLCProgramBuilder.Module.constant(i < m.inValues.count ? m.inValues[i] : 0)
            }
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
            let roles = Self.outputRoles(for: m, shape: shape)
            for role in roles {
                if case .hidden = role { continue }   // a hidden pin sets the flag and writes nothing
                if case .restOfInPins = role {
                    if longSwitch { put(UInt16(m.inPinCount - 2)) }
                    for i in 1..<max(1, m.inPinCount) { put(inValue(i)) }
                    continue
                }
                if case .systemCommand = role {
                    let variant = m.systemCommand
                    put(feeds[1] ?? variant.map { PLCProgramBuilder.Module.constant(Int($0.command)) } ?? inValue(1))
                    for (index, hidden) in [variant?.input1.isHidden ?? false, variant?.input2.isHidden ?? true].enumerated()
                    where !hidden {
                        put(feeds[Self.paramKeyBase + index]
                            ?? PLCProgramBuilder.Module.constant(index < m.paramValues.count ? m.paramValues[index] : 0))
                    }
                    put(slotWord(m).map { 0x1000 + $0 } ?? PLCProgramBuilder.Module.constant(0))
                    continue
                }
                if case .digitalOutputs = role {
                    // One word per registered channel; the channels the sheet hides are constant 0 and
                    // the visible ones take in-pins 1, 2, … in order (`rulkoshaddirigo`: 14 channels, mask
                    // `$0473` → channels 2, 3, 7, 8, 9, 11, 12, 13 are in-pins 1…8).
                    let channels = m.pinCount ?? max(0, m.inPinCount - 1)
                    let hidden = m.hiddenPinMask ?? 0
                    var pin = 1
                    for channel in 0..<channels {
                        if channel < Int.bitWidth, hidden & (1 << channel) != 0 {
                            put(PLCProgramBuilder.Module.constant(0))
                        } else {
                            put(inValue(pin))
                            pin += 1
                        }
                    }
                    continue
                }
                let value: UInt16
                switch role {
                case .slot:
                    // `0x1000 + ROWINDEX` of the module's own symbol row, from Dirigo's symbol table.
                    value = slotWord(m).map { 0x1000 + $0 } ?? PLCProgramBuilder.Module.constant(0)
                case .terminal(let umisteni, let svorka):
                    value = PLCProgramBuilder.Module.terminal(umisteni: umisteni, svorka: svorka)
                case .feedback(let svorka):
                    // The module's own out-pin `svorka`, through the same allocation the symbol table is
                    // generated from. Unlike `ownTerminal` this is deliberately *not* a sheet pin: it is
                    // the class closing a loop on itself, so it neither advances the wire index nor is
                    // supplied by the adapter.
                    value = allocation?.addresses[UInt16(m.umisteni) << 8 | UInt16(svorka)]?.word
                        ?? PLCProgramBuilder.Module.terminal(umisteni: m.umisteni, svorka: UInt8(svorka))
                case .ownTerminalIfPin(let svorka):
                    guard m.outPinCount > svorka else { continue }
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
                case .inPin(let index):
                    value = feeds[index] ?? PLCProgramBuilder.Module.constant(0)
                case .inPinOrConstant(let index):
                    value = feeds[index] ?? constant()
                case .paramPinOrConstant(let index):
                    value = feeds[Self.paramKeyBase + index] ?? constant()
                case .inPinOrValue(let index):
                    value = inValue(index)
                case .paramPinOrValue(let index):
                    value = feeds[Self.paramKeyBase + index]
                        ?? PLCProgramBuilder.Module.constant(index < m.paramValues.count ? m.paramValues[index] : 0)
                case .restOfInPins, .digitalOutputs, .systemCommand:
                    continue
                case .wire:
                    // A wire, or — when nothing feeds the pin — the pin's constant, which the encoder
                    // gives as 0 for an unset value. Only `.unassigned` positions consume `constants`,
                    // because those are the class's declared constant pins; a `.wire` position that the
                    // sheet leaves open is a pin the class still treats as a wire.
                    value = feeds[pin] ?? PLCProgramBuilder.Module.constant(0)
                    pin += 1
                case .zero:
                    value = PLCProgramBuilder.Module.constant(0)
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
        var starts: [Int: Int] = [:]
        let region = try records(modules: modules, wires: wires, slots: slots, wireValue: { $0.value },
                                 allocation: PLCSymbolTable(modules: modules, wires: wires,
                                                            classForGUID: classForGUID, shapes: shapes),
                                 threadStarts: &starts)
        return PLCProgramTable.assemble(template: template, records: region, threadStarts: starts)
    }

    /// The same, with the slots and the wire values taken from a generated `PLCSymbolTable`.
    public func table(fromTemplate template: PLCProgramTable, modules: [Module], wires: [Wire],
                      allocation: PLCSymbolTable) throws -> [UInt8] {
        var starts: [Int: Int] = [:]
        let region = try records(modules: modules, wires: wires, slots: allocation.slots,
                                 wireValue: { allocation.value(fromWire: $0) ?? PLCProgramBuilder.Module.constant(0) },
                                 allocation: allocation, threadStarts: &starts)
        return PLCProgramTable.assemble(template: template, records: region, threadStarts: starts)
    }

    /// `{ABC}` and `ABC` are the same GUID; the project file and the id table differ in brace style.
    public static func normaliseGUID(_ guid: String) -> String {
        guid.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }
}
