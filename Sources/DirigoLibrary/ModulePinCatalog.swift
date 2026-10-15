import Foundation
import DirigoCore

public struct PinSchema: Sendable {
    public let shortcut: String
    public let name: String
    public let dataType: String

    public init(shortcut: String, name: String, dataType: String = "") {
        self.shortcut = shortcut
        self.name = name
        self.dataType = dataType
    }
}

/// The three pin-name lists for one module.
public typealias PinSchemas = (inPins: [PinSchema], paramPins: [PinSchema], outPins: [PinSchema])

public struct ModulePinCatalog: Sendable {
    /// What the schema for a module depends on, so a cache hit cannot return a stale answer.
    ///
    /// It carries the three pin counts and **every attribute the table below reads** — not a subset,
    /// because a schema that silently ignored one would label a pin wrongly rather than crash, which is
    /// the failure mode this file already has tests for (`PinLabelTests`).
    private struct SchemaKey: Hashable {
        var name: String
        var guid: UUID?
        var inCount: Int
        var paramCount: Int
        var outCount: Int
        var attrs: AttributeBag
    }

    private static let schemaLock = NSLock()
    nonisolated(unsafe) private static var schemaCache: [Int: (key: SchemaKey, value: PinSchemas)] = [:]

    /// `pinNames(for:)` is a pure function of the module's name, guid, pin counts and attributes, and it
    /// is **not cheap**: building a schema allocates a `PinSchema` per pin. Measured on `had.pcc` it cost
    /// **1.2–2.5 ms per call**, and the inspector calls it once per row per body — with the canvas
    /// re-evaluating at the simulation rate, that is hundreds of milliseconds of pure recomputation, and
    /// it is why opening the sidebar on a selected block felt slow.
    ///
    /// Keyed by module id and validated against `SchemaKey`, so a hit is an answer for *these* pins.
    /// Guarded by a lock rather than confined to the main actor because `pinNames` is `nonisolated` —
    /// the wire router and the geometry helpers call it off the view path.
    public static func pinNames(for module: PCCModule) -> PinSchemas {
        let key = SchemaKey(name: module.name, guid: module.guid,
                            inCount: module.inPins.count, paramCount: module.paramPins.count,
                            outCount: module.outPins.count, attrs: module.rawAttributes)
        schemaLock.lock()
        if let hit = schemaCache[module.id], hit.key == key {
            schemaLock.unlock()
            return hit.value
        }
        schemaLock.unlock()

        let built = fit(pinNames(for: module.name, guid: module.guid, rawAttrs: module.rawAttributes),
                        to: module)
        schemaLock.lock()
        schemaCache[module.id] = (key, built)
        schemaLock.unlock()
        return built
    }

    /// Drops every memoised schema. Called when a project is loaded, so a new document cannot be served
    /// answers for a module id that used to mean something else.
    public static func invalidateSchemaCache() {
        schemaLock.lock()
        schemaCache.removeAll()
        schemaLock.unlock()
    }

    /// The schema for a module, with its name matched against the block table.
    ///
    /// The match is by the *longest prefix* of the cleaned name: a sheet names its blocks freely, so
    /// `Int2BitsLeft` and `Int2BitsDO` must still find `Int2Bits`. Matching the whole name meant those two
    /// fell through to the default and lost every pin label — `Input 0`/`Output 0` instead of `X`/`B0…B6`
    /// — which is what `ruleta_kostka_had.pcc` shows.
    public static func pinNames(for moduleName: String, guid: UUID? = nil, rawAttrs: AttributeBag = [:]) -> (inPins: [PinSchema], paramPins: [PinSchema], outPins: [PinSchema]) {
        let clean = moduleName.filter { !$0.isNumber }.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = schema(named: clean, rawAttrs: rawAttrs) { return exact }
        // Progressively shorter prefixes, so a descriptive suffix does not cost the block its names.
        var candidate = clean
        while candidate.count > 2 {
            candidate.removeLast()
            if let match = schema(named: candidate, rawAttrs: rawAttrs) { return match }
        }
        return (inPins: [], paramPins: [], outPins: [])
    }

    /// A schema fitted to what the sheet actually declares.
    ///
    /// A schema names pins; the sheet says how many there are, and the two can disagree because a *wrong*
    /// block matched — `Bits2Int`'s schema has eight bit *inputs*, and applying it to a one-input block
    /// labelled the input with the first output's name, which is how the panel came to show `B0 (Bit 0)`
    /// twice. A bit run whose length disagrees with the sheet is therefore dropped, so the module's own
    /// names are used instead.
    private static func fit(_ schema: (inPins: [PinSchema], paramPins: [PinSchema], outPins: [PinSchema]),
                            to module: PCCModule) -> (inPins: [PinSchema], paramPins: [PinSchema], outPins: [PinSchema]) {
        guard !(module.inPins.isEmpty && module.outPins.isEmpty && module.paramPins.isEmpty) else {
            return schema
        }
        return (inPins: fitted(schema.inPins, to: module.inPins.count),
                paramPins: fitted(schema.paramPins, to: module.paramPins.count),
                outPins: fitted(schema.outPins, to: module.outPins.count))
    }

    private static func fitted(_ pins: [PinSchema], to count: Int) -> [PinSchema] {
        guard !pins.isEmpty, pins.count != count else { return pins }
        // A run of bits is a block whose count comes from the sheet; anything else that disagrees is a
        // different block's schema.
        let isBitRun = pins.allSatisfy { pin in
            pin.shortcut.hasPrefix("B") && Int(pin.shortcut.dropFirst()) != nil
        }
        guard isBitRun else { return [] }
        return (0..<count).map { PinSchema(shortcut: "B\($0)", name: "Bit \($0)", dataType: pins[0].dataType) }
    }

    /// The block table itself. Returns `nil` when nothing matches, which is what lets the prefix search
    /// above retry.
    private static func schema(named clean: String, rawAttrs: AttributeBag) -> (inPins: [PinSchema], paramPins: [PinSchema], outPins: [PinSchema])? {
        switch clean {
        // --- Logic & Bitwise ---
        case "and":
            let andCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 2
            let andPins = [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")] +
                (0..<andCount).map { PinSchema(shortcut: "X\($0)", name: "X\($0)", dataType: "Boolean") }
            return (
                inPins: andPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Boolean")]
            )
        case "or", "orspin":
            let orCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 2
            let orPins = [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")] +
                (0..<orCount).map { PinSchema(shortcut: "X\($0)", name: "X\($0)", dataType: "Boolean") }
            return (
                inPins: orPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Boolean")]
            )
        case "not":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "A", dataType: "Boolean")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Boolean")]
            )
        case "xor":
            let xorCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 2
            let xorPins = [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")] +
                (0..<xorCount).map { PinSchema(shortcut: "X\($0)", name: "X\($0)", dataType: "Boolean") }
            return (
                inPins: xorPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Boolean")]
            )
        case "rs":
            let isS = (rawAttrs["PRIORITY"]?.uppercased() == "S") || (rawAttrs["RS_PRIORITY"]?.uppercased() == "S")
            let sLabel = isS ? "*S" : "S"
            let rLabel = isS ? "R" : "*R"
            return (
                inPins: [
                    PinSchema(shortcut: sLabel, name: isS ? "Set (Higher Priority)" : "Set", dataType: "Boolean"),
                    PinSchema(shortcut: rLabel, name: isS ? "Reset" : "Reset (Higher Priority)", dataType: "Boolean")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "State (Y)", dataType: "Boolean")]
            )
        case "trigger":
            return (
                inPins: [PinSchema(shortcut: "X", name: "Input", dataType: "Boolean")],
                paramPins: [],
                outPins: [
                    PinSchema(shortcut: "R", name: "Rising", dataType: "Boolean"),
                    PinSchema(shortcut: "F", name: "Falling", dataType: "Boolean")
                ]
            )

        // --- Comparators & Switching ---
        case "comparator":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Int"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Int")
                ],
                paramPins: [],
                outPins: [
                    PinSchema(shortcut: "AGtB", name: "A greater than B", dataType: "Boolean"),
                    PinSchema(shortcut: "AEqB", name: "A equal B", dataType: "Boolean"),
                    PinSchema(shortcut: "ALtB", name: "A less than B", dataType: "Boolean")
                ]
            )
        case "hystcomparator", "hysteresis", "hysteresiscomparator":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int")
                ],
                paramPins: [
                    PinSchema(shortcut: "Lo", name: "Low Limit", dataType: "Int"),
                    PinSchema(shortcut: "Hi", name: "High Limit", dataType: "Int")
                ],
                outPins: [PinSchema(shortcut: "Y", name: "Output", dataType: "Boolean")]
            )
        case "mcompare", "multicomparator":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int")
                ],
                paramPins: [
                    PinSchema(shortcut: "Ref", name: "Reference", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Gt", name: "Greater", dataType: "Boolean"),
                    PinSchema(shortcut: "Eq", name: "Equal", dataType: "Boolean"),
                    PinSchema(shortcut: "Lt", name: "Less", dataType: "Boolean")
                ]
            )
        case "iswitch":
            let inCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 2
            let xPins = (0..<inCount).map { PinSchema(shortcut: "X\($0)", name: "Input \($0)", dataType: "Int") }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Sw", name: "Switch", dataType: "Int")
                ] + xPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Out", dataType: "Int")]
            )
        case "lswitch":
            let inCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 2
            let xPins = (0..<inCount).map { PinSchema(shortcut: "X\($0)", name: "Input \($0)", dataType: "Long") }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Sw", name: "Switch", dataType: "Int")
                ] + xPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Out", dataType: "Long")]
            )
        case "fswitch":
            let inCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 2
            let xPins = (0..<inCount).map { PinSchema(shortcut: "X\($0)", name: "Input \($0)", dataType: "Float") }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Sw", name: "Switch", dataType: "Int")
                ] + xPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Out", dataType: "Float")]
            )
        case "idemux", "intdemux":
            let outCount = rawAttrs["OUTPUT_COUNT"].flatMap { Int($0) } ?? 4
            let yPins = (0..<outCount).map { PinSchema(shortcut: "Y\($0)", name: "Output \($0)", dataType: "Int") }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Idx", name: "Index", dataType: "Int"),
                    PinSchema(shortcut: "X", name: "Input", dataType: "Int")
                ],
                paramPins: [],
                outPins: yPins
            )
        case "ldemux":
            let outCount = rawAttrs["OUTPUT_COUNT"].flatMap { Int($0) } ?? 4
            let yPins = (0..<outCount).map { PinSchema(shortcut: "Y\($0)", name: "Output \($0)", dataType: "Long") }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Idx", name: "Index", dataType: "Int"),
                    PinSchema(shortcut: "X", name: "Input", dataType: "Long")
                ],
                paramPins: [],
                outPins: yPins
            )
        case "fdemux", "floatdemux":
            let outCount = rawAttrs["OUTPUT_COUNT"].flatMap { Int($0) } ?? 4
            let yPins = (0..<outCount).map { PinSchema(shortcut: "Y\($0)", name: "Output \($0)", dataType: "Float") }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Idx", name: "Index", dataType: "Int"),
                    PinSchema(shortcut: "X", name: "Input", dataType: "Float")
                ],
                paramPins: [],
                outPins: yPins
            )

        // --- Conversion & Bit Manipulation ---
        case "intbits", "int2bits":
            let bitCount = rawAttrs["OUTPUT_COUNT"].flatMap { Int($0) } ?? 8
            let bPins = (0..<bitCount).map { PinSchema(shortcut: "B\($0)", name: "Bit \($0)", dataType: "Boolean") }
            return (
                inPins: [PinSchema(shortcut: "X", name: "X", dataType: "Int")],
                paramPins: [],
                outPins: bPins
            )
        case "bitsint", "bits2int":
            let bitCount = rawAttrs["INPUT_COUNT"].flatMap { Int($0) } ?? 8
            let bPins = (0..<bitCount).map { PinSchema(shortcut: "B\($0)", name: "Bit \($0)", dataType: "Boolean") }
            return (
                inPins: bPins,
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Integer", dataType: "Int")]
            )
        case "shl":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int"),
                    PinSchema(shortcut: "N", name: "Shift Count", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "sar", "shr":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int"),
                    PinSchema(shortcut: "N", name: "Shift Count", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "ext":
            return (
                inPins: [
                    PinSchema(shortcut: "X", name: "Source", dataType: "Int"),
                    PinSchema(shortcut: "Pos", name: "Position", dataType: "Int"),
                    PinSchema(shortcut: "Len", name: "Length", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Extracted", dataType: "Int")]
            )
        case "ins":
            return (
                inPins: [
                    PinSchema(shortcut: "Dst", name: "Destination", dataType: "Int"),
                    PinSchema(shortcut: "Src", name: "Source", dataType: "Int"),
                    PinSchema(shortcut: "Pos", name: "Position", dataType: "Int"),
                    PinSchema(shortcut: "Len", name: "Length", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Result", dataType: "Int")]
            )

        // --- Math & Arithmetic ---
        case "add", "iadd":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Int"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "sub", "isub":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Int"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "mul", "imul":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Int"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "div", "idiv":
            var outP = [PinSchema(shortcut: "Y", name: "Y (A / B)", dataType: "Long")]
            let showMod = rawAttrs["MODULO_VISIBLE"]?.lowercased() == "true" || rawAttrs["SHOW_MODULO"]?.lowercased() == "true"
            if showMod {
                outP.append(PinSchema(shortcut: "Mod", name: "Modulo (A % B)", dataType: "Int"))
            }
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Long"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Int")
                ],
                paramPins: [],
                outPins: outP
            )
        case "abs", "iabs":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "Input", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "inc", "iinc":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int")
                ],
                paramPins: [PinSchema(shortcut: "St", name: "Step", dataType: "Int")],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "neg", "ineg":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "Operand", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Negation", dataType: "Int")]
            )
        case "fadd":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Float"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Float")]
            )
        case "fsub":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Float"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Float")]
            )
        case "fmul":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Float"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Float")]
            )
        case "fdiv":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "A", dataType: "Float"),
                    PinSchema(shortcut: "B", name: "B", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Float")]
            )
        case "fabs":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Float")]
            )
        case "fsin":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "Angle Rad", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Sin", dataType: "Float")]
            )
        case "fcos":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "Angle Rad", dataType: "Float")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Cos", dataType: "Float")]
            )

        // --- Timing & Oscillators ---
        case "pulsegen":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Act", name: "Active", dataType: "Boolean")
                ],
                paramPins: [
                    PinSchema(shortcut: "TOn", name: "Time On", dataType: "Int"),
                    PinSchema(shortcut: "TOff", name: "Time Off", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Cnt", name: "Counter", dataType: "Int"),
                    PinSchema(shortcut: "Out", name: "Output", dataType: "Boolean")
                ]
            )
        case "singlepulse":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Tr", name: "Trigger", dataType: "Boolean")
                ],
                paramPins: [
                    PinSchema(shortcut: "TOn", name: "Time On", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Cnt", name: "Counter", dataType: "Int"),
                    PinSchema(shortcut: "Out", name: "Output", dataType: "Boolean")
                ]
            )
        case "pulselen", "pulselength":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Tr", name: "Trigger", dataType: "Boolean")
                ],
                paramPins: [
                    PinSchema(shortcut: "TLen", name: "Time Length", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Cnt", name: "Counter", dataType: "Int"),
                    PinSchema(shortcut: "Out", name: "Output", dataType: "Boolean")
                ]
            )
        case "timer":
            return (
                inPins: [
                    PinSchema(shortcut: "In", name: "Input", dataType: "Boolean")
                ],
                paramPins: [
                    PinSchema(shortcut: "PT", name: "Preset Time", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Q", name: "Output", dataType: "Boolean"),
                    PinSchema(shortcut: "ET", name: "Elapsed Time", dataType: "Int")
                ]
            )

        // --- Counters ---
        case "counter":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Tr", name: "Trigger", dataType: "Boolean"),
                    PinSchema(shortcut: "Rst", name: "Reset", dataType: "Boolean")
                ],
                paramPins: [
                    PinSchema(shortcut: "St", name: "Step", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Y", name: "Y", dataType: "Int")
                ]
            )
        case "advcounter", "cnt":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Tr", name: "Trigger", dataType: "Boolean"),
                    PinSchema(shortcut: "Rst", name: "Reset", dataType: "Boolean"),
                    PinSchema(shortcut: "Pres", name: "Preset", dataType: "Boolean"),
                    PinSchema(shortcut: "EnH", name: "EnableH", dataType: "Boolean"),
                    PinSchema(shortcut: "EnL", name: "EnableL", dataType: "Boolean")
                ],
                paramPins: [
                    PinSchema(shortcut: "PV", name: "PresetVal", dataType: "Int"),
                    PinSchema(shortcut: "Max", name: "Maximum", dataType: "Int"),
                    PinSchema(shortcut: "Min", name: "Minimum", dataType: "Int"),
                    PinSchema(shortcut: "St", name: "Step", dataType: "Int")
                ],
                outPins: [
                    PinSchema(shortcut: "Y", name: "Y", dataType: "Int"),
                    PinSchema(shortcut: "H", name: "High", dataType: "Boolean"),
                    PinSchema(shortcut: "L", name: "Low", dataType: "Boolean")
                ]
            )

        // --- Display & Visualization ---
        case "segment":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "A", name: "Segment A", dataType: "Boolean"),
                    PinSchema(shortcut: "B", name: "Segment B", dataType: "Boolean"),
                    PinSchema(shortcut: "C", name: "Segment C", dataType: "Boolean"),
                    PinSchema(shortcut: "D", name: "Segment D", dataType: "Boolean"),
                    PinSchema(shortcut: "E", name: "Segment E", dataType: "Boolean"),
                    PinSchema(shortcut: "F", name: "Segment F", dataType: "Boolean"),
                    PinSchema(shortcut: "G", name: "Segment G", dataType: "Boolean"),
                    PinSchema(shortcut: "DP", name: "Decimal Point", dataType: "Boolean")
                ],
                paramPins: [],
                outPins: []
            )

        // --- I/O Peripherals ---
        case "xdi", "8xdi":
            // 8xDI can have custom mask (PIN_MASK) or active pin count up to 16
            let diMask: Int = {
                if let raw = rawAttrs["PIN_MASK"] {
                    return PinMask.parse(raw)
                }
                return 0xFF
            }()
            let showAll = rawAttrs["PIN_ALL_VISIBLE"]?.lowercased() == "true"
            var diPins: [PinSchema] = []
            for i in 0..<16 {
                if showAll || (diMask & (1 << i)) != 0 || i < 8 {
                    // Only include if bit is enabled in mask, or baseline 0..7
                    if (diMask & (1 << i)) != 0 || (diMask == 0xFF && i < 8) {
                        diPins.append(PinSchema(shortcut: "DI\(i)", name: "DI \(i)", dataType: "Boolean"))
                    }
                }
            }
            if showAll {
                diPins.append(PinSchema(shortcut: "All", name: "Word (DI0..DI15)", dataType: "Int"))
            }
            return (
                inPins: [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")],
                paramPins: [],
                outPins: diPins
            )
        case "xdo", "8xdo":
            let pinCount = rawAttrs["PIN_COUNT"].flatMap { Int($0) } ?? 8
            let hiddenMask: Int = {
                if let raw = rawAttrs["HIDDEN_PIN_MASK"] {
                    return PinMask.parse(raw)
                }
                return 0
            }()
            var doPins: [PinSchema] = []
            for i in 0..<pinCount {
                if (hiddenMask & (1 << i)) == 0 {
                    doPins.append(PinSchema(shortcut: "DO\(i)", name: "DO \(i)", dataType: "Boolean"))
                }
            }
            return (
                inPins: [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")] + doPins,
                paramPins: [],
                outPins: []
            )
        case "xai", "8xai":
            return (
                inPins: [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")],
                paramPins: [],
                outPins: (0...7).map { PinSchema(shortcut: "AI\($0)", name: "AI \($0)", dataType: "Int") }
            )
        case "xao", "2xao":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "AO0", name: "AO 0", dataType: "Int"),
                    PinSchema(shortcut: "AO1", name: "AO 1", dataType: "Int")
                ],
                paramPins: [],
                outPins: []
            )

        // --- Regulation & Ramp ---
        case "ramp":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int")
                ],
                paramPins: [
                    PinSchema(shortcut: "SU", name: "Step up", dataType: "Int"),
                    PinSchema(shortcut: "SD", name: "Step down", dataType: "Int")
                ],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "limiter", "llimiter":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int"),
                    PinSchema(shortcut: "Min", name: "Minimum", dataType: "Int"),
                    PinSchema(shortcut: "Max", name: "Maximum", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Int")]
            )
        case "inrange":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "X", name: "X", dataType: "Int"),
                    PinSchema(shortcut: "Min", name: "Minimum", dataType: "Int"),
                    PinSchema(shortcut: "Max", name: "Maximum", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "In Range", dataType: "Boolean")]
            )

        // --- System & Control ---
        case "systemcmd":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "Cmd", name: "Command", dataType: "Int")
                ],
                paramPins: [
                    PinSchema(shortcut: "Par1", name: "Parametr1", dataType: "Int"),
                    PinSchema(shortcut: "Par2", name: "Parametr2", dataType: "Int")
                ],
                outPins: [PinSchema(shortcut: "Out", name: "Output", dataType: "Int")]
            )
        case "set":
            return (
                inPins: [PinSchema(shortcut: "X", name: "Value", dataType: "Int")],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Output", dataType: "Int")]
            )
        case "yes":
            return (
                inPins: [PinSchema(shortcut: "X", name: "X", dataType: "Boolean")],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Boolean")]
            )
        case "copy":
            return (
                inPins: [
                    PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                    PinSchema(shortcut: "In", name: "Input", dataType: "Int")
                ],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Out", name: "Output", dataType: "Int")]
            )

        // --- Variables ---
        case "boolvar", "roztoctruletu", "prepinacrezim":
            return (
                inPins: [],
                paramPins: [],
                outPins: [PinSchema(shortcut: "Y", name: "Y", dataType: "Boolean")]
            )
        case "intvar":
            return (
                inPins: [],
                paramPins: [PinSchema(shortcut: "Init", name: "Initial Value", dataType: "Int")],
                outPins: [PinSchema(shortcut: "Y", name: "Value", dataType: "Int")]
            )
        case "longvar":
            return (
                inPins: [],
                paramPins: [PinSchema(shortcut: "Init", name: "Initial Value", dataType: "Long")],
                outPins: [PinSchema(shortcut: "Y", name: "Value", dataType: "Long")]
            )
        case "floatvar":
            return (
                inPins: [],
                paramPins: [PinSchema(shortcut: "Init", name: "Initial Value", dataType: "Float")],
                outPins: [PinSchema(shortcut: "Y", name: "Value", dataType: "Float")]
            )

        // --- Date & Time ---
        case "datetime":
            var inP = [PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean")]
            if rawAttrs["SHOW_OFFSET"]?.lowercased() == "true" || rawAttrs["OFFSET_VISIBLE"]?.lowercased() == "true" {
                inP.append(PinSchema(shortcut: "Offs", name: "Offset (seconds)", dataType: "Long"))
            }
            var outP = [
                PinSchema(shortcut: "D", name: "Day (days since 1.1.1980)", dataType: "Long"),
                PinSchema(shortcut: "H", name: "Hour", dataType: "Int"),
                PinSchema(shortcut: "M", name: "Minute", dataType: "Int"),
                PinSchema(shortcut: "S", name: "Second", dataType: "Int"),
                PinSchema(shortcut: "DOW", name: "Day of Week (0=Mon..6=Sun)", dataType: "Int")
            ]
            if rawAttrs["SHOW_SOD"]?.lowercased() == "true" || rawAttrs["SOD_VISIBLE"]?.lowercased() == "true" {
                outP.append(PinSchema(shortcut: "SOD", name: "Second of Day (0..86399)", dataType: "Long"))
            }
            return (inPins: inP, paramPins: [], outPins: outP)

        // --- 8xPWM ---
        case "8xpwm", "pwm":
            let inP: [PinSchema] = [
                PinSchema(shortcut: "En", name: "Enabled", dataType: "Boolean"),
                PinSchema(shortcut: "AO0", name: "AO 0", dataType: "Int"),
                PinSchema(shortcut: "AO1", name: "AO 1", dataType: "Int"),
                PinSchema(shortcut: "AO2", name: "AO 2", dataType: "Int"),
                PinSchema(shortcut: "AO3", name: "AO 3", dataType: "Int"),
                PinSchema(shortcut: "AO4", name: "AO 4", dataType: "Int"),
                PinSchema(shortcut: "AO5", name: "AO 5", dataType: "Int"),
                PinSchema(shortcut: "AO6", name: "AO 6", dataType: "Int"),
                PinSchema(shortcut: "AO7", name: "AO 7", dataType: "Int")
            ]
            let outP: [PinSchema] = [
                PinSchema(shortcut: "DO0", name: "PWM Out 0", dataType: "Boolean"),
                PinSchema(shortcut: "DO1", name: "PWM Out 1", dataType: "Boolean"),
                PinSchema(shortcut: "DO2", name: "PWM Out 2", dataType: "Boolean"),
                PinSchema(shortcut: "DO3", name: "PWM Out 3", dataType: "Boolean"),
                PinSchema(shortcut: "DO4", name: "PWM Out 4", dataType: "Boolean"),
                PinSchema(shortcut: "DO5", name: "PWM Out 5", dataType: "Boolean"),
                PinSchema(shortcut: "DO6", name: "PWM Out 6", dataType: "Boolean"),
                PinSchema(shortcut: "DO7", name: "PWM Out 7", dataType: "Boolean")
            ]
            return (inPins: inP, paramPins: [PinSchema(shortcut: "N", name: "Steps", dataType: "Int")], outPins: outP)

        default:
            return nil
        }
    }

    public static func inputPinLabel(for module: PCCModule, index: Int) -> String {
        if index < module.inPins.count, let name = module.inPins[index].name, !name.isEmpty {
            return name
        }
        let schema = pinNames(for: module)
        if index < schema.inPins.count {
            return schema.inPins[index].shortcut
        }
        return "X\(index)"
    }

    public static func inputPinFullName(for module: PCCModule, index: Int) -> String {
        let schema = pinNames(for: module)
        if index < schema.inPins.count {
            return "\(schema.inPins[index].shortcut) (\(schema.inPins[index].name))"
        }
        if index < module.inPins.count, let name = module.inPins[index].name, !name.isEmpty {
            return name
        }
        return "Input \(index)"
    }

    public static func outputPinLabel(for module: PCCModule, index: Int) -> String {
        if index < module.outPins.count, let name = module.outPins[index].name, !name.isEmpty {
            return name
        }
        let schema = pinNames(for: module)
        if index < schema.outPins.count {
            return schema.outPins[index].shortcut
        }
        return "Y\(index)"
    }

    public static func outputPinFullName(for module: PCCModule, index: Int) -> String {
        let schema = pinNames(for: module)
        if index < schema.outPins.count {
            return "\(schema.outPins[index].shortcut) (\(schema.outPins[index].name))"
        }
        if index < module.outPins.count, let name = module.outPins[index].name, !name.isEmpty {
            return name
        }
        return "Output \(index)"
    }

    public static func paramPinLabel(for module: PCCModule, index: Int) -> String {
        if index < module.paramPins.count, let name = module.paramPins[index].name, !name.isEmpty {
            return name
        }
        let schema = pinNames(for: module)
        if index < schema.paramPins.count {
            return schema.paramPins[index].shortcut
        }
        return "P\(index)"
    }

    public static func paramPinFullName(for module: PCCModule, index: Int) -> String {
        let schema = pinNames(for: module)
        if index < schema.paramPins.count {
            return "\(schema.paramPins[index].shortcut) (\(schema.paramPins[index].name))"
        }
        if index < module.paramPins.count, let name = module.paramPins[index].name, !name.isEmpty {
            return name
        }
        return "Param \(index)"
    }
}
