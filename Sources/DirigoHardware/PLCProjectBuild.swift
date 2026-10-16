import Foundation

/// One project compiled: the records, the program table, the symbol table, and what was left out.
///
/// The app's *Build* menu and `dirigo-cli build` both go through here, so the two cannot drift: what the
/// UI reports is what the command prints, and both are the compiler the tests pin against `had.dmp` and
/// the real symbol tables.
public struct PLCProjectBuild: Equatable, Sendable {
    /// What the build could and could not do. Counts are of *modules*, not classes.
    public struct Report: Equatable, Sendable {
        public var moduleCount: Int
        /// Modules whose class has a record shape that contributes to the program.
        public var compiledModules: Int
        /// Modules on the sheet that are not in the program at all — the displays.
        public var displayModules: Int
        /// Modules whose class has no shape yet, and the classes themselves.
        public var unshapedModules: [String]
        public var unshaped: [String]
        /// Modules whose GUID is not a block at all: a sheet saved as a block, expanded by hand.
        public var macros: [String]
        public var recordBytes: Int
        public var dataSlots: Int
        public var terminals: Int
        public var symbolRows: Int
        /// What the optimising pass did, when it ran.
        public var optimization: Optimization?

        /// The summary both front ends show, in the same words.
        public var lines: [String] {
            var out = [
                "\(compiledModules) of \(moduleCount) modules compiled, \(recordBytes) bytes of records."
                    + (displayModules > 0 ? " \(displayModules) display module(s) write no record." : ""),
                "\(dataSlots) data slot(s), \(terminals) terminal(s), \(symbolRows) symbol row(s).",
            ]
            if !unshaped.isEmpty {
                out.append("\(unshaped.count) class(es) have no record shape yet: "
                           + unshaped.prefix(6).joined(separator: ", ")
                           + (unshaped.count > 6 ? ", …" : ""))
                out.append("   modules: " + unshapedModules.prefix(8).joined(separator: ", ")
                           + (unshapedModules.count > 8 ? ", …" : ""))
            }
            if let optimization {
                var line = "Optimised: \(optimization.bytesSaved) byte(s) saved"
                if optimization.bytesSaved > 0, !optimization.removedModules.isEmpty {
                    line += ", \(optimization.removedModules.count) unused module(s) dropped"
                }
                line += "; a value crosses the program in \(optimization.cyclesAfter) cycle(s) instead of \(optimization.cyclesBefore)."
                out.append(line)
            }
            if !macros.isEmpty {
                out.append("\(macros.count) macro module(s) were left out: "
                           + macros.prefix(4).joined(separator: ", ")
                           + (macros.count > 4 ? ", …" : ""))
            }
            return out
        }

        /// True when every module either compiled, writes no record by design, or is a macro.
        public var isComplete: Bool { unshaped.isEmpty }
    }

    /// What `PLCProgramOptimizer` changed.
    public struct Optimization: Equatable, Sendable {
        public var removedModules: [String]
        public var bytesSaved: Int
        public var cyclesBefore: Int
        public var cyclesAfter: Int
        public var movedModules: Int
    }

    /// One module's share of the record region.
    public struct ModuleRecord: Equatable, Sendable {
        public var name: String
        /// The implementing class, or `nil` when the GUID is a macro.
        public var className: String?
        /// How many bytes this module's record takes.
        public var bytes: Int
        /// Whether it is part of the program at all (a display writes nothing).
        public var contributes: Bool
    }

    /// Per module, in file order — what the region is actually made of.
    public var moduleRecords: [ModuleRecord]

    public var report: Report
    /// The 256-byte program table, ready to be wrapped as a `.pbd`.
    public var table: [UInt8]
    /// The record region that went into the table's body.
    public var records: [UInt8]
    /// The symbol table as Dirigo's `.csv`.
    public var symbolCSV: String

    /// Compiles a project's XML.
    ///
    /// - Parameters:
    ///   - xml: the project as `.pcc`, which is what the compiler's readers take.
    ///   - classForGUID: normalised GUID to implementing class name. A GUID that is absent is a macro.
    ///   - template: the table whose header and profile are carried into the build.
    public static func compile(xml: String, classForGUID: [String: String],
                               template: PLCProgramTable, optimize: Bool = false) throws -> PLCProjectBuild {
        // Each call of a macro gets its own copy of the sheet (see `PLCProjectCompiler.instanced`).
        let (modules, rawWires) = PLCProjectCompiler.instanced(
            modules: PLCProjectCompiler.modules(in: xml), wires: PLCProjectCompiler.wires(in: xml))
        let wires = PLCProjectCompiler.resolvingMacroInterfaces(modules: modules, wires: rawWires)
        let normalised = Dictionary(uniqueKeysWithValues: classForGUID.map {
            (PLCProjectCompiler.normaliseGUID($0.key), $0.value)
        })
        let inProgram = PLCProjectCompiler.programModules(modules)
        let allocation = PLCSymbolTable(modules: inProgram, wires: wires,
                                        classForGUID: normalised,
                                        shapes: PLCProjectCompiler.classShapes)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: normalised)
        var ordered = PLCProjectCompiler.recordOrder(modules)
        var optimization: Optimization?
        if optimize {
            let before = try compiler.records(modules: ordered, wires: wires, allocation: allocation).count
            let result = PLCProgramOptimizer.optimize(ordered, wires: wires, allModules: modules, classForGUID: normalised)
            ordered = result.modules
            let after = try compiler.records(modules: ordered, wires: wires, allocation: allocation).count
            optimization = Optimization(removedModules: result.removed, bytesSaved: before - after,
                                        cyclesBefore: result.cyclesBefore, cyclesAfter: result.cyclesAfter,
                                        movedModules: result.moved)
        }
        let records = try compiler.records(modules: ordered, wires: wires, allocation: allocation)
        let table = try compiler.table(fromTemplate: template, modules: ordered, wires: wires,
                                       allocation: allocation)

        var compiled = 0, displays = 0
        var unshapedClasses: Set<String> = []
        var unshapedModules: [String] = []
        var macros: [String] = []
        for module in modules {
            guard let cls = normalised[PLCProjectCompiler.normaliseGUID(module.guid)] else {
                macros.append(module.name)
                continue
            }
            guard let shape = PLCProjectCompiler.classShapes[cls] else {
                unshapedClasses.insert(cls)
                unshapedModules.append(module.name)
                continue
            }
            if shape.contributesRecord { compiled += 1 } else { displays += 1 }
        }

        // Each module measured on its own: the roles write a word whether or not a wire resolves, so a
        // module's record length does not depend on the rest of the project.
        var perModule: [ModuleRecord] = []
        for module in modules {
            let cls = normalised[PLCProjectCompiler.normaliseGUID(module.guid)]
            let length = (try? compiler.records(modules: [module], wires: [], allocation: allocation).count) ?? 0
            let contributes = cls.flatMap { PLCProjectCompiler.classShapes[$0]?.contributesRecord } ?? false
            perModule.append(ModuleRecord(name: module.name, className: cls, bytes: length,
                                          contributes: contributes))
        }

        let report = Report(
            moduleCount: modules.count,
            compiledModules: compiled,
            displayModules: displays,
            unshapedModules: unshapedModules.sorted(),
            unshaped: unshapedClasses.sorted(),
            macros: macros.sorted(),
            recordBytes: records.count,
            dataSlots: allocation.addresses.values.filter { !$0.isBoolean }.count,
            terminals: allocation.addresses.values.filter { $0.isBoolean }.count,
            symbolRows: allocation.rows.count,
            optimization: optimization)
        return PLCProjectBuild(moduleRecords: perModule, report: report, table: table, records: records,
                               symbolCSV: allocation.csv)
    }
}

public extension PLCProgramTable {
    /// The table a build starts from when no `.pbd` was imported.
    ///
    /// Only the established fields are filled: the version (`1` in every real table, `movw $0x1`,
    /// 0x4B0A07), the trailer's constant and its profile name, and the rest is left zero. The trailer
    /// is what the captures show for `Sybas Control P3`, at the sentinel of a 256-byte table. Its records
    /// are replaced by the build, so only its trailer is used. A header that matters should come from a
    /// program binary Dirigo wrote, which carries the project flags too.
    static func buildTemplate() -> PLCProgramTable? {
        let size = 256
        var bytes = [UInt8](repeating: 0, count: size)
        bytes[PLCProgramTable.versionOffset] = 1
        // `07 00 01 01` at 0x04 and `04` at 0x22 are the same in all four tables seen (640, 640, 256, 192 bytes).
        // 0x10, 0x1A and 0x26 differ per project and are not yet derived; the table's checksum covers them.
        bytes[0x04] = 7; bytes[0x06] = 1; bytes[0x07] = 1; bytes[0x22] = 4
        let sentinel = size - PLCProgramTable.trailerLength
        bytes[sentinel] = 0xFF
        bytes[sentinel + 1] = 0xFF
        bytes[sentinel + 11] = 0x01
        for (i, byte) in [UInt8(0xD0), 0x00, 0xD0, 0x00].enumerated() {
            bytes[sentinel + 12 + i] = byte
        }
        let name = Array("Sybas Control P3".utf8)
        for i in 0..<PLCProgramTable.profileLength {
            bytes[sentinel + 16 + i] = i < name.count ? name[i] : 0x20
        }
        return try? PLCProgramTable(bytes: bytes)
    }

    /// The table inside a program binary, if the file has one. The table is the section's payload after
    /// its eight-byte sub-header, and it runs to the end of the payload.
    static func from(image: PLCProgramImage) -> PLCProgramTable? {
        guard let section = image.blocks.first(where: { $0.id == PLCProgramImage.programTableSection }),
              section.payload.count > 8 else { return nil }
        return try? PLCProgramTable(bytes: Array(section.payload[8...]))
    }
}
