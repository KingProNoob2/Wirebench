import Foundation
import DirigoCore
import DirigoLibrary
import DirigoEngine
import DirigoHardware

@main
struct DirigoCLI {
    static func main() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.count >= 2 else {
            printUsage()
            return
        }

        let command = args[1]
        switch command {
        case "info":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli info <project.pcc>")
                return
            }
            inspectProject(path: args[2])

        case "sim":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli sim <project.pcc> [ticks] [--profile-scheduling]")
                return
            }
            let ticks = args.dropFirst(3).compactMap { Int($0) }.first ?? 100
            let useProfileScheduling = args.contains("--profile-scheduling")
            runSimulation(path: args[2], ticks: ticks, useProfileScheduling: useProfileScheduling)

        case "roundtrip":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli roundtrip <project.pcc>")
                return
            }
            verifyRoundtrip(path: args[2])

        case "audit-blocks":
            // Exercises every block type in the catalog: instantiate, step, report.
            print(BlockAuditor.report(BlockAuditor.auditAll()))

        case "blocks":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli blocks <project.pcc>")
                return
            }
            reportBlocks(path: args[2])

        case "build":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli build <project.pcc> [--out <dir>] [--template <program.pbd>] [--quiet] [--optimize]")
                return
            }
            buildProject(path: args[2], options: Array(args.dropFirst(3)))

        case "pins":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli pins <project.pcc> [module]")
                return
            }
            printPinRows(path: args[2], module: args.count >= 4 ? args[3] : nil)

        case "symbols":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli symbols <project.pcc>")
                return
            }
            printSymbolTable(path: args[2])

        case "profile":
            guard args.count >= 3 else {
                print("Error: Missing file path. Usage: dirigo-cli profile <project.pcc> [Profiles.ini]")
                return
            }
            reportProfile(path: args[2], profilesPath: args.count >= 4 ? args[3] : nil)

        default:
            print("Unknown command: \(command)")
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        DirigoSwift CLI - Reverse Engineered PLC Engine
        ================================================
        Usage:
          dirigo-cli info <project.pcc>         Inspect project structure and components
          dirigo-cli sim <project.pcc> [ticks]  Run deterministic simulation benchmark
          dirigo-cli roundtrip <project.pcc>    Verify lossless XML AST roundtrip fidelity
          dirigo-cli blocks <project.pcc>       Show how each module resolves to a block type
          dirigo-cli profile <project.pcc> [Profiles.ini]
                                                Show the hardware profile and SystemCmd catalogue
          dirigo-cli build <project.pcc> [--out <dir>] [--template <program.pbd>] [--quiet]
                                                Compile the project to <name>.pbd and <name>.csv.
                                                --optimize drops unused and switched-off (En = 0) logic and math,
                                                and puts the records in dataflow
                                                order, so values settle in fewer PLC cycles.
                                                --template carries a real export's table, header and
                                                profile into the build. Exits 1 if any module's class
                                                has no record shape yet.
          dirigo-cli symbols <project.pcc>      Write the generated symbol table to stdout as CSV
          dirigo-cli pins <project.pcc> [module]
                                                Print the pin rows the inspector draws, with the block
                                                table's names — the quickest way to tell a display
                                                problem from a project one
        """)
    }

    static func inspectProject(path: String) {
        let url = URL(fileURLWithPath: path)
        let parser = PCCParser()
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let project = try parser.parse(fileAt: url)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            print("\n✅ Successfully parsed: \(url.lastPathComponent) in \(String(format: "%.2f", elapsed)) ms")
            print("-------------------------------------------------------------------")
            print("  Application     : \(project.application) \(project.applicationVersion)")
            print("  Profile         : \(project.profile)")
            print("  Cycle Delay     : \(project.appOptions.cycleDelay) ms")
            print("  Pages           : \(project.pages.count) (\(project.pages.map { $0.caption }.joined(separator: ", ")))")
            print("  Modules         : \(project.modules.count)")
            print("  In Connections  : \(project.inConnections.count)")
            print("  Param Conns     : \(project.paramConnections.count)")
            print("  Graphics shapes : \(project.graphics.count)")
            print("-------------------------------------------------------------------")

            print("\nModules by Page:")
            let pages = Dictionary(grouping: project.modules, by: { $0.page })
            for (page, mods) in pages.sorted(by: { $0.key < $1.key }) {
                print("  📄 Page [\(page)] (\(mods.count) modules):")
                for m in mods.prefix(8) {
                    print("     - ID \(m.id): \(m.name) (Thread: \(m.threadId), Order: \(m.order))")
                }
                if mods.count > 8 {
                    print("     ... and \(mods.count - 8) more")
                }
            }
        } catch {
            print("❌ Failed to parse project: \(error)")
        }
    }

    static func runSimulation(path: String, ticks: Int, useProfileScheduling: Bool = false) {
        let url = URL(fileURLWithPath: path)
        let parser = PCCParser()
        do {
            let project = try parser.parse(fileAt: url)

            let database = useProfileScheduling ? ProfileRegistry.load() : nil
            let profile = database.flatMap { ProfileRegistry.profile(for: project, in: $0) }
            let scheduling: SimulationEngine.ThreadScheduling = useProfileScheduling ? .profileIntervals : .everyTick
            if useProfileScheduling, profile == nil {
                print("Warning: Profiles.ini not found; falling back to every-tick scheduling")
            }
            let engine = SimulationEngine(project: project, profile: profile, scheduling: scheduling)

            if let profile, useProfileScheduling {
                print("Profile '\(profile.name)': "
                      + profile.threads.map { "\($0.name)=\($0.intervalMs)ms" }.joined(separator: ", "))
            }

            let unresolved = engine.unresolvedBlocks()
            if !unresolved.isEmpty {
                print("\nNote: \(unresolved.count) module(s) have no implementation and run inert:")
                print("  " + unresolved.map(\.module.name).sorted().joined(separator: ", "))
            }

            print("\n🚀 Starting simulation benchmark for \(ticks) ticks on '\(url.lastPathComponent)'...")
            let start = CFAbsoluteTimeGetCurrent()
            engine.run(ticks: ticks)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let ticksPerSec = Double(ticks) / elapsed

            print("✅ Completed \(ticks) ticks in \(String(format: "%.4f", elapsed)) seconds")
            print("⚡ Performance: \(String(format: "%.0f", ticksPerSec)) ticks/sec (\(String(format: "%.3f", (elapsed / Double(ticks)) * 1000)) ms/tick)")

            if scheduling == .profileIntervals {
                print("\nThread executions:")
                for (tid, count) in engine.threadRunCounts.sorted(by: { $0.key < $1.key }) {
                    let name = profile?.thread(id: tid)?.name ?? "(undefined thread \(tid))"
                    print("  T\(tid) \(name): \(count) run(s), interval \(Int(engine.intervalMs(forThread: tid))) ms")
                }
            }

            print("\nSample Module States after simulation:")
            for m in project.modules.prefix(10) {
                if let node = engine.getNode(id: m.id) {
                    let outs = node.block.outPins.map { "\($0)" }.joined(separator: ", ")
                    print("  - \(m.name) (ID \(m.id)): Outputs = [\(outs)]")
                }
            }
        } catch {
            print("❌ Simulation error: \(error)")
        }
    }

    /// Compares a save against the file it came from. Unlike a parse/serialise/parse count check
    /// this actually detects data loss: it compares the re-emitted document with the original
    /// after decoding character references and ignoring inter-tag whitespace.
    static func verifyRoundtrip(path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            let project = try PCCParser().parse(fileAt: url)
            let reEmitted = PCCSerializer().serialize(project: project)
            let reparsed = try PCCParser().parse(xmlString: reEmitted)

            print("\nRound-trip fidelity for \(url.lastPathComponent)")
            print(String(repeating: "-", count: 78))
            print("  modules      : \(project.modules.count) -> \(reparsed.modules.count)")
            print("  wires        : \(project.inConnections.count) -> \(reparsed.inConnections.count)")
            print("  param wires  : \(project.paramConnections.count) -> \(reparsed.paramConnections.count)")
            print("  pages        : \(project.pages.count) -> \(reparsed.pages.count)")
            print("  graphics     : \(project.graphics.count) -> \(reparsed.graphics.count)")

            var problems: [String] = []
            if project.modules.count != reparsed.modules.count { problems.append("module count changed") }
            if project.inConnections.count != reparsed.inConnections.count { problems.append("wire count changed") }
            if project.paramConnections.count != reparsed.paramConnections.count { problems.append("param wire count changed") }
            if project.sectionOrder != reparsed.sectionOrder { problems.append("section order changed") }
            if project.rawAttributes.keys != reparsed.rawAttributes.keys { problems.append("root attributes changed") }
            if project.rawSections != reparsed.rawSections { problems.append("unmodelled sections changed") }

            for (before, after) in zip(project.modules, reparsed.modules) {
                if before.rawAttributes.keys != after.rawAttributes.keys {
                    problems.append("\(before.name): module attributes changed")
                }
                if before.inPins.map(\.rawAttributes.keys) != after.inPins.map(\.rawAttributes.keys) {
                    problems.append("\(before.name): input pin attributes changed")
                }
                if before.inPins.compactMap(\.name) != after.inPins.compactMap(\.name) {
                    problems.append("\(before.name): input pin names changed")
                }
                if before.outPins.compactMap(\.name) != after.outPins.compactMap(\.name) {
                    problems.append("\(before.name): output pin names changed")
                }
            }

            // Byte-level check when we can read the original as text.
            if let original = try? String(contentsOf: url, encoding: .utf8) {
                if original == reEmitted {
                    print("\n  byte-exact: the re-emitted document is identical to the original")
                } else {
                    let canonicalOriginal = canonicalXML(original)
                    let canonicalEmitted = canonicalXML(reEmitted)
                    if canonicalOriginal == canonicalEmitted {
                        print("\n  content-exact: identical once whitespace and character-reference")
                        print("  spelling are normalised (the original uses an older Dirigo XML writer)")
                    } else {
                        problems.append("content differs from the original document")
                    }
                }
            }

            print("")
            if problems.isEmpty {
                print("  no data loss detected")
            } else {
                print("  DATA LOSS:")
                for problem in problems.prefix(20) { print("     - \(problem)") }
                if problems.count > 20 { print("     ... and \(problems.count - 20) more") }
            }
        } catch {
            print("Round-trip validation failed: \(error)")
        }
    }

    /// Decodes numeric character references and drops whitespace outside quoted attribute values.
    static func canonicalXML(_ xml: String) -> String {
        var decoded = String.UnicodeScalarView()
        let scalars = Array(xml.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&", i + 1 < scalars.count, scalars[i + 1] == "#" {
                var j = i + 2
                var radix = 10
                if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" { radix = 16; j += 1 }
                var digits = ""
                while j < scalars.count, scalars[j] != ";" { digits.unicodeScalars.append(scalars[j]); j += 1 }
                if j < scalars.count, scalars[j] == ";", !digits.isEmpty,
                   let value = UInt32(digits, radix: radix), let scalar = UnicodeScalar(value) {
                    decoded.append(scalar)
                    i = j + 1
                    continue
                }
            }
            decoded.append(scalars[i])
            i += 1
        }

        var out = String.UnicodeScalarView()
        var inQuotes = false
        for scalar in decoded {
            if scalar == "\"" { inQuotes.toggle(); out.append(scalar); continue }
            if !inQuotes, scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" { continue }
            out.append(scalar)
        }
        return String(out)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Reports, per module, which block class handles it, and calls out anything unresolved.
    static func reportBlocks(path: String) {
        do {
            let project = try PCCParser().parse(fileAt: URL(fileURLWithPath: path))
            let registry = BlockRegistry.shared
            var unresolved: [PCCModule] = []
            var byType: [String: Int] = [:]

            print("\nBlock-type resolution for \(URL(fileURLWithPath: path).lastPathComponent)")
            print(String(repeating: "-", count: 92))
            print("  " + pad("module", 20) + pad("Dirigo type", 16) + pad("Swift class", 18) + "GUID")

            for module in project.modules.sorted(by: { $0.id < $1.id }) {
                let info = BlockTypeCatalog.info(forGuid: module.guid)
                let resolved = registry.resolvedTypeName(for: module)
                if resolved == nil { unresolved.append(module) }
                let typeName = info?.blockName ?? "?"
                byType[typeName, default: 0] += 1
                print("  " + pad(module.name, 20) + pad(typeName, 16)
                      + pad(resolved?.description ?? "UNRESOLVED", 18) + module.guid.uuidString)
            }

            print(String(repeating: "-", count: 92))
            print("  \(project.modules.count) modules across \(byType.count) block types")
            if unresolved.isEmpty {
                print("  every module resolves to an implementation")
            } else {
                print("  WARNING: \(unresolved.count) module(s) have no implementation and run inert:")
                for module in unresolved {
                    let info = BlockTypeCatalog.info(forGuid: module.guid)
                    print("     - \(module.name)  (\(info?.blockName ?? "unknown") / \(info?.delphiClass ?? "?"))")
                }
            }
        } catch {
            print("Failed to parse project: \(error)")
        }
    }

    static func reportProfile(path: String, profilesPath: String?) {
        let searchPaths = profilesPath.map { [URL(fileURLWithPath: $0)] }
        guard let database = ProfileRegistry.load(searchPaths: searchPaths) else {
            print("Could not find Profiles.ini. Pass its path explicitly.")
            return
        }
        do {
            let project = try PCCParser().parse(fileAt: URL(fileURLWithPath: path))
            print("\nProfiles.ini: \(database.profiles.count) profiles, "
                  + "\(database.systemCommands.count) system commands")
            if let defaultProfile = database.defaultProfile {
                print("Default profile: \(defaultProfile.name)")
            }

            guard let profile = ProfileRegistry.profile(for: project, in: database) else {
                print("Project asks for profile '\(project.profile)' which is not defined")
                return
            }
            print("\nProject uses profile '\(profile.name)'"
                  + (profile.alias.map { " (alias \($0))" } ?? ""))
            print(String(repeating: "-", count: 92))
            print("  CPU             : \(profile.cpuBits)-bit")
            print("  Programme size  : \(profile.programDataSize.map(String.init) ?? "-") bytes")
            print("  RAM  (I/L/F)    : \(profile.intRamSize)/\(profile.longRamSize)/\(profile.floatRamSize) bytes")
            print("  ROM  (I/L/F)    : \(profile.intRomSize)/\(profile.longRomSize)/\(profile.floatRomSize) bytes")
            print("  EEPROM          : offset \(profile.eepromOffset), \(profile.eepromDataSize) bytes, "
                  + "write block \(profile.eepromWriteBlock)")
            print("  Direct constant : \(profile.directConstMin)..\(profile.directConstMax)")
            print("  Constant types  : \(profile.constantDataTypes.joined(separator: ", "))"
                  + "  (aliases: \(profile.constantDataTypeAliases.joined(separator: ", ")))")

            print("\n  Threads:")
            for thread in profile.threads {
                let used = project.modules.filter { $0.threadId == thread.id }.count
                print("    T" + pad(String(thread.id), 4) + pad(thread.name, 20)
                      + pad("\(thread.intervalMs) ms", 10) + "\(used) module(s)")
            }
            let unknownThreads = Set(project.modules.map(\.threadId))
                .subtracting(profile.threads.map(\.id))
            if !unknownThreads.isEmpty {
                print("    (the project also uses THREAD_ID values this profile does not define: "
                      + "\(unknownThreads.sorted()))")
            }

            let commands = database.systemCommands(for: profile)
            print("\n  SystemCmd commands available on this profile: \(commands.count)")
            for command in commands.sorted(by: { $0.mnemonic < $1.mnemonic }) {
                func pin(_ schema: SystemCommandInfo.PinSchema) -> String {
                    schema.isHidden ? "(\(schema.name))" : schema.name
                }
                print("    " + pad(command.mnemonic, 12)
                      + pad(String(format: "0x%04X", command.command), 9)
                      + pad(command.text, 8)
                      + pad("I1=\(pin(command.input1))", 18)
                      + pad("I2=\(pin(command.input2))", 18)
                      + "O1=\(pin(command.output))")
            }
        } catch {
            print("Failed to parse project: \(error)")
        }
    }

    // MARK: - Building

    /// Compiles a project the way the app's *Build* menu does — `PLCProjectBuild` is the one implementation
    /// both call — and writes the two artefacts Dirigo itself writes: a program binary and a symbol table.
    static func buildProject(path: String, options: [String]) {
        let url = URL(fileURLWithPath: path)
        var outDirectory = url.deletingLastPathComponent()
        var templateURL: URL?
        var quiet = false
        var showModules = false
        var optimize = false
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--out":
                guard index + 1 < options.count else { print("--out needs a directory"); exit(2) }
                outDirectory = URL(fileURLWithPath: options[index + 1])
                index += 2
            case "--template":
                guard index + 1 < options.count else { print("--template needs a file"); exit(2) }
                templateURL = URL(fileURLWithPath: options[index + 1])
                index += 2
            case "--quiet":
                quiet = true
                index += 1
            case "--modules":
                showModules = true
                index += 1
            case "--optimize":
                optimize = true
                index += 1
            default:
                print("Unknown option: \(options[index])")
                index += 1
            }
        }

        do {
            // The file is compiled as it stands, not through a parse/serialize round trip.
            let xml = try String(contentsOf: url, encoding: .utf8)
            var header: [UInt8]?
            var template = PLCProgramTable.buildTemplate()
            if let templateURL {
                let image = try PLCProgramImage.load(contentsOf: templateURL)
                guard let fromImage = PLCProgramTable.from(image: image) else {
                    print("Error: \(templateURL.lastPathComponent) has no 525 program table")
                    exit(1)
                }
                template = fromImage
                header = image.header
            }
            guard let template else {
                print("Error: could not prepare a program table")
                exit(1)
            }

            let build = try PLCProjectBuild.compile(xml: xml,
                                                    classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                    template: template, optimize: optimize)
            let binary = try PLCProgramImage.programBinary(table: build.table,
                                                          projectName: url.lastPathComponent,
                                                          header: header)
            let base = url.deletingPathExtension().lastPathComponent
            let binaryURL = outDirectory.appendingPathComponent(base + ".pbd")
            let csvURL = outDirectory.appendingPathComponent(base + ".csv")
            try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
            try Data(binary).write(to: binaryURL, options: .atomic)
            try build.symbolCSV.write(to: csvURL, atomically: true, encoding: .utf8)

            if showModules || !build.report.isComplete {
                print("\nRecords by module (\(build.records.count) bytes, table \(build.table.count) bytes)")
                print(String(repeating: "-", count: 72))
                for record in build.moduleRecords {
                    let cls = record.className ?? "macro"
                    let note = record.contributes ? "" : "  (writes no record)"
                    print("  " + pad(record.name, 18) + pad(cls, 24) + pad("\(record.bytes) B", 7) + note)
                }
            }
            if !quiet {
                print("\nBuild of \(url.lastPathComponent)")
                print(String(repeating: "-", count: 72))
                for line in [build.report.countsLine] + build.report.lines { print("  " + line) }
                print(String(repeating: "-", count: 72))
                print("  \(binaryURL.path)  (\(binary.count) bytes)")
                print("  \(csvURL.path)  (\(build.report.symbolRows) rows)")
                if templateURL == nil {
                    print("  header: this app's default — pass --template <program.pbd> to carry Dirigo's own")
                }
                print("  hidden-pin flags are not in the project: every record is written with a zero flag")
                print("  pass --modules to list what each module contributed")
            }
            if !build.report.isComplete { exit(1) }
        } catch {
            print("Build failed: \(error)")
            exit(1)
        }
    }

    /// Prints the rows the inspector would draw for each module: the label, then the pin's own name.
    ///
    /// The inspector names pins through `ModulePinCatalog`, so this shows the same strings from the same
    /// call. When a label looks wrong in the app, running this on the same file says whether the label or
    /// the file is the one that is out of step.
    static func printPinRows(path: String, module: String?) {
        do {
            let project = try PCCParser().parse(fileAt: URL(fileURLWithPath: path))
            let wanted = project.modules.filter { module == nil || $0.name == module }
            guard !wanted.isEmpty else {
                print("No module named \(module ?? "") in \(URL(fileURLWithPath: path).lastPathComponent)")
                exit(1)
            }
            for mod in wanted {
                let info = BlockTypeCatalog.info(forGuid: mod.guid)
                let schema = ModulePinCatalog.pinNames(for: mod)
                print("\n\(mod.name)  [\(info?.blockName ?? "?") / \(info?.delphiClass ?? "?")]"
                      + "  in=\(mod.inPins.count) param=\(mod.paramPins.count) out=\(mod.outPins.count)")
                print("  block table: in=\(schema.inPins.map { $0.shortcut })"
                      + " out=\(schema.outPins.map { $0.shortcut })")
                for i in 0..<mod.inPins.count {
                    print("  in [\(i)] \(ModulePinCatalog.inputPinFullName(for: mod, index: i))"
                          + "   (pin name: \(mod.inPins[i].name ?? "none"))")
                }
                for i in 0..<mod.paramPins.count {
                    print("  par[\(i)] \(ModulePinCatalog.paramPinFullName(for: mod, index: i))"
                          + "   (pin name: \(mod.paramPins[i].name ?? "none"))")
                }
                for i in 0..<mod.outPins.count {
                    print("  out[\(i)] \(ModulePinCatalog.outputPinFullName(for: mod, index: i))"
                          + "   (pin name: \(mod.outPins[i].name ?? "none"))")
                }
            }
        } catch {
            print("Failed to read the project: \(error)")
            exit(1)
        }
    }

    /// Writes the generated symbol table to stdout, exactly as the file would be.
    static func printSymbolTable(path: String) {
        do {
            let xml = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            guard let template = PLCProgramTable.buildTemplate() else { exit(1) }
            let build = try PLCProjectBuild.compile(xml: xml,
                                                    classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                    template: template)
            // Written through the file handle so no newline is appended: the CSV's own CRLFs are the file.
            FileHandle.standardOutput.write(Data(build.symbolCSV.utf8))
        } catch {
            print("Failed to compile: \(error)")
            exit(1)
        }
    }
}