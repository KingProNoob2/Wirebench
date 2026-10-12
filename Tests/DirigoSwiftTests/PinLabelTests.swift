import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoLibrary

/// Pin labels, against every project on disk.
///
/// The panel and the block cards name pins from `ModulePinCatalog`, so a wrong name is not cosmetic: it is
/// how a wire gets connected to the wrong place. Two defects were found by sweeping the corpus this way,
/// both from matching a module's *name* to the block table:
///
/// * a name with a suffix (`Int2BitsLeft`, `Int2BitsDO`) matched nothing, so the block lost every label —
///   `Input 0`/`Output 0` instead of `X`/`B0…B6`;
/// * a name that matched the *wrong* block applied its schema anyway, which is how a one-input block ended
///   up with its input labelled `B0 (Bit 0)` — the same label as its first output, so the panel showed
///   that row twice.
@Suite("Pin labels")
struct PinLabelTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static var school: URL {
        URL(fileURLWithPath: "/Users/erik/Nextcloud/School")
            .appendingPathComponent("Informační a Řídící Systémy").appendingPathComponent("Dirigo")
    }

    static var projects: [URL] {
        var out: [URL] = []
        for dir in [root, school] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            out += names.filter { $0.lowercased().hasSuffix(".pcc") }.sorted()
                .map { dir.appendingPathComponent($0) }
        }
        return out
    }

    @Test("No schema labels an input the same as one of the module's outputs")
    func noCollisions() throws {
        // Scoped to the *schema's* names on purpose: a sheet may legitimately reuse a name (a macro's
        // `PN` appears on both sides in `binarni scitacka.pcc`), and that is the document's business. What
        // must never happen is the block table describing one pin as another.
        let files = Self.projects
        var collisions: [String] = []
        var named = 0
        for url in files {
            guard let project = try? PCCParser().parse(fileAt: url) else { continue }
            for mod in project.modules {
                let schema = ModulePinCatalog.pinNames(for: mod)
                let ins = schema.inPins.map { "\($0.shortcut) (\($0.name))" }
                let outs = Set(schema.outPins.map { "\($0.shortcut) (\($0.name))" })
                // A schema side that survives fitting must describe the sheet exactly; a side that could
                // not is dropped, which is why an empty side is fine here and a mismatched one is not.
                if !schema.inPins.isEmpty {
                    named += ins.count
                    #expect(schema.inPins.count == mod.inPins.count,
                            "\(mod.name): schema has \(schema.inPins.count) inputs, the sheet \(mod.inPins.count)")
                }
                if !schema.outPins.isEmpty {
                    #expect(schema.outPins.count == mod.outPins.count,
                            "\(mod.name): schema has \(schema.outPins.count) outputs, the sheet \(mod.outPins.count)")
                }
                for name in ins where outs.contains(name) {
                    collisions.append("\(url.lastPathComponent): \(mod.name) — \(name)")
                }
            }
        }
        #expect(files.count >= 20, "the corpus should be on disk: found \(files.count)")
        #expect(named > 0, "no pin was named from a schema at all")
        #expect(collisions.isEmpty, "\(collisions.count) schema label collision(s): \(collisions.prefix(6))")
    }

    @Test("A suffixed block name still finds its block")
    func suffixesStillMatch() throws {
        // `ruleta_kostka_had.pcc` names its converters `Int2BitsMode`, `Int2BitsLeft`, `Int2BitsRight` and
        // `Int2BitsDO`; all four used to fall through to the default.
        let url = Self.root.appendingPathComponent("ruleta_kostka_had.pcc")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let project = try PCCParser().parse(fileAt: url)
        let guid = UUID(uuidString: "F319DECC-7D91-4684-A813-83DBB5C70245")!
        let converters = project.modules.filter { $0.guid == guid }
        #expect(converters.count == 4)
        for mod in converters {
            #expect(ModulePinCatalog.inputPinFullName(for: mod, index: 0) == "X (X)",
                    "\(mod.name) should name its input from the Int2Bits schema")
            #expect(ModulePinCatalog.outputPinFullName(for: mod, index: 0) == "B0 (Bit 0)",
                    "\(mod.name) should name its first bit")
        }
    }

    @Test("A bit run follows the sheet's own count")
    func bitRunFollowsTheSheet() throws {
        // `zelznice`'s converter has sixteen bits and no `OUTPUT_COUNT`, so the schema's default of eight
        // must not truncate the labels.
        let url = Self.school.appendingPathComponent("ehhhhhh zelznice.pcc")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let project = try PCCParser().parse(fileAt: url)
        let guid = UUID(uuidString: "F319DECC-7D91-4684-A813-83DBB5C70245")!
        let mod = try #require(project.modules.first { $0.guid == guid })
        #expect(mod.outPins.count == 16)
        #expect(ModulePinCatalog.outputPinFullName(for: mod, index: 15) == "B15 (Bit 15)")
    }

    /// `pinNames(for:)` is memoised, because it is called once per inspector row per body and cost
    /// **1.2–2.5 ms** per call — enough that selecting a block visibly lagged. A cache here is only safe
    /// if a hit is an answer for *these* pins, so this checks the two ways it could go wrong: a hit that
    /// differs from a fresh computation, and a hit that survives a change it should not.
    @Test("The memoised pin schema matches a fresh one, and expires when the module changes")
    func schemaCacheIsFaithful() {
        var project = PCCProject(name: "cache")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: UUID(), name: "And1", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                      inPins: (0..<4).map { Pin(id: $0, value: .bool(false)) },
                      outPins: [Pin(id: 0, value: .bool(false))],
                      rawAttributes: ["INPUT_COUNT": "3"]),
        ]
        let module = project.modules[0]

        // A hit must equal what the uncached path would have produced. `pinNames(for:name:guid:rawAttrs:)`
        // plus `fit` is that path, and it is what the cache is built from.
        let cached = ModulePinCatalog.pinNames(for: module)
        let fresh = ModulePinCatalog.pinNames(for: module.name, guid: module.guid,
                                              rawAttrs: module.rawAttributes)
        #expect(cached.inPins.map(\.shortcut) == fresh.inPins.map(\.shortcut),
                "a cache hit returned different in-pin shortcuts")
        #expect(cached.outPins.map(\.shortcut) == fresh.outPins.map(\.shortcut),
                "a cache hit returned different out-pin shortcuts")
        #expect(cached.inPins.map(\.name) == fresh.inPins.map(\.name),
                "a cache hit returned different in-pin names")

        // Every pin label the inspector draws agrees with the uncached computation.
        for index in 0..<module.inPins.count {
            let label = ModulePinCatalog.inputPinFullName(for: module, index: index)
            let expected: String = {
                guard index < fresh.inPins.count else { return "Input \(index)" }
                return "\(fresh.inPins[index].shortcut) (\(fresh.inPins[index].name))"
            }()
            #expect(label == expected, "in[\(index)] label \"\(label)\" != \"\(expected)\"")
        }

        // **Invalidation on an attribute the table reads.** `INPUT_COUNT` decides the `X<n>` run, so the
        // same module id under a different value is a different schema. Asserted against the *uncached*
        // path rather than a hand-computed count: `fit` trims a schema when its run disagrees with the
        // sheet, and predicting that here is how the first two versions of this test were wrong.
        for (count, pins) in [("1", 2), ("3", 4), ("6", 7)] {
            project.modules[0].rawAttributes["INPUT_COUNT"] = count
            project.modules[0].inPins = (0..<pins).map { Pin(id: $0, value: .bool(false)) }
            let cached = ModulePinCatalog.pinNames(for: project.modules[0])
            let fresh = ModulePinCatalog.pinNames(for: project.modules[0].name,
                                                  guid: project.modules[0].guid,
                                                  rawAttrs: project.modules[0].rawAttributes)
            let stale = "INPUT_COUNT=\(count) with \(pins) pins served a stale schema:"
                + " \(cached.inPins.map(\.shortcut)) vs \(fresh.inPins.map(\.shortcut))"
            #expect(cached.inPins.map(\.shortcut) == fresh.inPins.map(\.shortcut), "\(stale)")
            #expect(cached.inPins.map(\.name) == fresh.inPins.map(\.name),
                    "INPUT_COUNT=\(count) served stale pin names")
        }

        // A load clears the cache, so a module id cannot carry answers into another document.
        ModulePinCatalog.invalidateSchemaCache()
        let afterReset = ModulePinCatalog.pinNames(for: project.modules[0])
        #expect(afterReset.inPins.count > 0,
                "the schema came back empty after an explicit invalidation")
    }
}
