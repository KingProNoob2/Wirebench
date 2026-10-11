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
}
