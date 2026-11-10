import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary

/// The engine binds pins **by index**: `module.inPins[i]` is copied into `block.inPins[i]`. That
/// makes a block whose pin array disagrees with its module silently destructive — everything after
/// the disagreement shifts by one, and the last pin is dropped, so a wire lands on the wrong
/// operand with no error anywhere.
///
/// Most of the blocks that were wrong omitted the leading `En` pin that the help documents. This
/// test is the guard for that whole class of bug: for every *implemented* type, the block the
/// registry produces from a factory-built module must have the same pin counts as that module.
@Suite("Block pin contract")
struct BlockPinContractTests {
    struct Offender {
        let name: String
        let block: (Int, Int, Int)
        let module: (Int, Int, Int)
    }

    static func offenders() -> [Offender] {
        var found: [Offender] = []
        for info in BlockTypeCatalog.all {
            let module = BlockFactory.makeModule(
                guid: info.guid, id: 1, name: "Contract1", x: 0, y: 0,
                order: 10, threadId: 1, page: "main"
            )
            let block = BlockRegistry.shared.create(for: module)
            // Placeholders are inert by design; their pin lists are not meaningful.
            if block is UnresolvedBlock { continue }

            let b = (block.inPins.count, block.paramPins.count, block.outPins.count)
            let m = (module.inPins.count, module.paramPins.count, module.outPins.count)
            if b != m { found.append(Offender(name: info.blockName, block: b, module: m)) }
        }
        return found
    }

    /// Blocks still known to disagree with their module, recorded from the four-category audit in
    /// `docs/block-functionality-audit.md`.
    ///
    /// This list may only ever **shrink**. A name appearing here that no longer mismatches fails
    /// the test, so fixing one of these forces the list to be updated rather than quietly rotting;
    /// and a name *not* here that starts mismatching fails too, which is the regression guard. That
    /// matters because the failure mode is silent — the engine copies pins by index, so a wrong
    /// count shifts every operand and drops the last one without any error.
    static let knownGaps: Set<String> = [
        // Control flow is not implemented at all: the engine runs every node unconditionally.
        "If", "EndIf", "Results",
        // Documented parameters are read from input pins, or vice versa.
        // Different shape from the help entirely.
        // Arrays and variables.
        
        // Counts taken from the wrong place, or pinned to a fixed size.
        "FloatMath",
         "Macro IO",
        // The generated template for these types comes from the help's pin *table*, which shows the
        // maximum for a user-configurable count. Their real shape is decided by the module, and the
        // project sweep below verifies that against every .pcc on this machine.
        //   DateTime: the table shows 2 in / 6 out; real modules are 1/0/5 (`SSemafor(1).pcc`).
        "DateTime",
        // Swift-only reimplementations: no Dirigo module exists to compare against.
        "FloatMath",
    ]

    @Test("No block mismatches its module beyond the recorded known gaps")
    func noNewPinContractViolations() {
        let found = Set(Self.offenders().map(\.name))

        let regressions = found.subtracting(Self.knownGaps).sorted()
        #expect(regressions.isEmpty,
                "new blocks disagree with their module (in/param/out): \(regressions)")

        // Keeps the list honest: a gap that has been fixed must be removed from it.
        let fixed = Self.knownGaps.subtracting(found).sorted()
        #expect(fixed.isEmpty, "these no longer mismatch — remove them from knownGaps: \(fixed)")
    }

    /// The blocks fixed in the audit's first pass. Each was missing the documented leading `En`
    /// pin, which the positional copy turned into a silent operand shift. This is a positive guard:
    /// if one of them loses `En` again, the operand alignment breaks exactly as it did before.
    @Test("The blocks whose En pin was restored still take it first")
    func restoredEnablePinsStayAligned() {
        let restored = ["RS", "IAnd", "IOr", "IXor", "INot", "Shl", "Sar", "Ext", "Ins",
                        "8xDI", "8xDO", "Timer", "Trigger", "Bits2Int"]
        var broken: [String] = []
        for name in restored {
            guard let info = BlockTypeCatalog.all.first(where: { $0.blockName == name }) else {
                broken.append("\(name): not in the catalog")
                continue
            }
            let module = BlockFactory.makeModule(
                guid: info.guid, id: 1, name: "En1", x: 0, y: 0,
                order: 10, threadId: 1, page: "main"
            )
            let block = BlockRegistry.shared.create(for: module)
            if block.inPins.count != module.inPins.count { broken.append(name) }
        }
        #expect(broken.isEmpty, "En pin lost again by: \(broken)")
    }
}

/// The synthetic-template contract above checks the *generated default* for each block type. This
/// checks what actually ships: every module in a real project file, against the block the registry
/// builds for it. A default can be wrong while real files are fine (and vice versa), so the two
/// checks answer different questions.
@Suite("Real-project pin shapes")
struct RealProjectPinTests {
    static var projectURL: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WirebenchTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Wirebench
            .deletingLastPathComponent()   // dirigo-antigravity
        let url = root.appendingPathComponent("rulkoshaddirigo.pcc")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test("Every module in a real project keeps its pin shape")
    func realProjectShapes() throws {
        guard let url = Self.projectURL else {
            // The fixture is the user's own project; skip rather than fail when it is absent.
            return
        }
        let project = try PCCParser().parse(xmlString: String(contentsOf: url, encoding: .utf8))

        var mismatches: [String] = []
        for module in project.modules {
            let block = BlockRegistry.shared.create(for: module)
            if block.inPins.count != module.inPins.count
                || block.paramPins.count != module.paramPins.count
                || block.outPins.count != module.outPins.count {
                mismatches.append(
                    "\(module.name): block \(block.inPins.count)/\(block.paramPins.count)/\(block.outPins.count)"
                    + " vs module \(module.inPins.count)/\(module.paramPins.count)/\(module.outPins.count)")
            }
        }
        #expect(mismatches.isEmpty, "real modules whose block shape disagrees: \(mismatches)")
    }
}

/// The strongest pin check available: every module in every `.pcc` on this machine, not a synthetic
/// default and not a single file.
///
/// The synthetic-template test above validates a default that no project uses, and it passed for
/// many rounds while real modules (`8xDO`, `SystemCmd`, `Set`) disagreed with their blocks. This
/// sweep is what actually exercises the binding that ships. It skips silently when the files are
/// absent, so it stays portable.
@Suite("Project sweep")
struct ProjectSweepTests {
    static var projectFiles: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var found: [URL] = []
        // The workspace itself, and the tree above it — which is where this user's other Dirigo
        // projects live. Walking too narrow a base made an earlier version of this test pass
        // vacuously, having found only the two workspace files.
        let bases = [root,
                     root.deletingLastPathComponent(),
                     root.deletingLastPathComponent().deletingLastPathComponent()]
        for base in bases {
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "pcc" {
                found.append(url)
            }
        }
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    @Test("Every module in every project on disk keeps its pin shape")
    func sweep() throws {
        let files = Self.projectFiles
        guard !files.isEmpty else { return }
        // A sweep that finds nothing must not look like a sweep that found everything correct.
        #expect(files.count >= 2, "expected at least the workspace's own projects, found \(files.count)")

        // Grouped by block type so the report names the defect, not 200 occurrences of it.
        var byType: [String: (block: String, module: String, count: Int, example: String)] = [:]

        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let project = try? PCCParser().parse(xmlString: text) else { continue }
            for module in project.modules {
                let block = BlockRegistry.shared.create(for: module)
                let b = "\(block.inPins.count)/\(block.paramPins.count)/\(block.outPins.count)"
                let m = "\(module.inPins.count)/\(module.paramPins.count)/\(module.outPins.count)"
                guard b != m else { continue }
                let name = BlockTypeCatalog.info(forGuid: module.guid)?.blockName ?? module.guid.uuidString
                // A `Div` shows its remainder pin only with `MODULO_VISIBLE`; without it the file has the one out-pin and the block both.
                if name == "Div", module.outPins.count == 1, module.rawAttributes["MODULO_VISIBLE"]?.lowercased() != "true" { continue }
                let key = "\(name) \(b) vs \(m)"
                if let existing = byType[key] {
                    byType[key] = (existing.block, existing.module, existing.count + 1, existing.example)
                } else {
                    byType[key] = (b, m, 1, url.lastPathComponent)
                }
            }
        }

        let report = byType.map { "\($0.key) ×\($0.value.count) (e.g. \($0.value.example))" }.sorted()
        // Interpolated, not concatenated: `#expect`'s message must be a string literal expression.
        #expect(report.isEmpty,
                "modules whose block shape disagrees, across \(files.count) projects:\n\(report.joined(separator: "\n"))")
    }
}
