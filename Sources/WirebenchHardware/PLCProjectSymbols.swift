import Foundation

extension PLCProjectCompiler {
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
        // Split on characters, not on "\n": a CRLF is one `Character`, and the file is CRLF.
        csv.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.dropFirst().compactMap { rawLine in
            let line = String(rawLine)
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
}
