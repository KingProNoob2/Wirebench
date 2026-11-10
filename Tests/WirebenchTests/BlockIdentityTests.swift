import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary

/// Guards the two ways a block's *identity* can silently break, as opposed to its behaviour.
///
/// The pin-contract tests compare pin counts; they would not notice a block registered under a GUID
/// that does not exist, or a block type that the catalog claims is implemented but which has no
/// implementation at all. Both fail quietly: the first turns a real module into an unresolved block,
/// the second makes a whole type inert.
@Suite("Block identity")
struct BlockIdentityTests {
    @Test("Every registered GUID exists in the recovered catalog")
    func registeredGuidsAreReal() {
        let catalog = Set(BlockTypeCatalog.all.map(\.guid))
        let fabricated = BlockRegistry.shared.registeredGuids.subtracting(catalog)
        #expect(fabricated.isEmpty,
                "these GUIDs are registered but appear nowhere in the recovered catalog: \(fabricated.sorted { $0.uuidString < $1.uuidString })")
    }

    @Test("Every type the catalog marks implemented can actually be built")
    func implementedTypesAreRegistered() {
        let registered = BlockRegistry.shared.registeredGuids
        // `Generic` and `Unresolved` are this engine's own fallbacks, not Dirigo module types, so
        // they are expected to have no factory of their own.
        let engineInternal: Set<String> = ["Generic", "Unresolved"]
        // Types the catalog flags as implemented but which this build still has no class for.
        // This list may only shrink.
        let knownMissing: Set<String> = []

        let missing = BlockTypeCatalog.all
            .filter { $0.isImplemented && !registered.contains($0.guid) }
            .map(\.blockName)
            .filter { !engineInternal.contains($0) && !knownMissing.contains($0) }
        #expect(missing.isEmpty, "the catalog says these are implemented, but no block is registered: \(missing)")
    }

    @Test("The known-missing list has no stale entries")
    func knownMissingIsAccurate() {
        let registered = BlockRegistry.shared.registeredGuids
        let stale = BlockTypeCatalog.all
            .filter { ["IInc", "FloatMath"].contains($0.blockName) && !registered.contains($0.guid) }
            .map(\.blockName)
        #expect(stale.isEmpty, "these now have implementations — remove them from knownMissing: \(stale)")
    }
}

/// A source-level guard, covering the layer `registeredGuids` cannot see.
///
/// `BlockIdentityTests` checks the GUIDs passed to `register(guid:)`. It cannot see a *class's own*
/// `static let guid`, because that value is never consulted for dispatch — so a mistyped or
/// placeholder literal there compiles, passes every behavioural test, and only fails at runtime
/// when something reads it. That happened once already (`UUID(uuidString: "GUID_PLACEHOLDER")!`).
@Suite("Block source identity")
struct BlockSourceIdentityTests {
    static var libraryDirectory: URL {
        // #filePath is <package>/Tests/WirebenchTests/<this file>.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WirebenchTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package>
            .appendingPathComponent("Sources/WirebenchLibrary")
    }

    /// GUIDs that belong to this reimplementation rather than to Dirigo, and are deliberately never
    /// used for dispatch.
    static let syntheticGuids: Set<String> = [
        // The engine's own fallback for an unknown type. It must NOT be registered: it is what
        // `create` returns when nothing matches. A v5 name-based UUID, like the others here.
        "09904072-D3B3-5455-932F-B18CA530EA60",   // UnresolvedBlock
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2CE",   // LongMathBlock
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2CF",   // FloatMathNumericBlock
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D6",   // HardwareInputBlock
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D5",   // ShapePreservingBlock
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D3",   // D3-Net block
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D2",   // D3-Net block
        "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D1",   // D3-Net block
    ]

    static func uuidLiterals(in source: String) -> [String] {
        var found: [String] = []
        var rest = Substring(source)
        while let range = rest.range(of: "uuidString: \"") {
            let after = rest[range.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            found.append(String(after[..<end]))
            rest = after[end...]
        }
        return found
    }

    @Test("Every UUID literal in the library is a real UUID")
    func everyLiteralParses() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.libraryDirectory, includingPropertiesForKeys: nil)) ?? []
        var malformed: [String] = []
        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for literal in Self.uuidLiterals(in: text) where UUID(uuidString: literal) == nil {
                malformed.append("\(file.lastPathComponent): \(literal)")
            }
        }
        #expect(malformed.isEmpty, "these are not valid UUIDs: \(malformed)")
    }

    @Test("Every GUID literal is either from the catalog or explicitly synthetic")
    func everyLiteralIsKnown() {
        let catalog = Set(BlockTypeCatalog.all.map { $0.guid.uuidString.uppercased() })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.libraryDirectory, includingPropertiesForKeys: nil)) ?? []
        var unknown: Set<String> = []
        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for literal in Self.uuidLiterals(in: text) {
                let upper = literal.uppercased()
                if !catalog.contains(upper) && !Self.syntheticGuids.contains(upper) {
                    unknown.insert(upper)
                }
            }
        }
        #expect(unknown.isEmpty,
                "these GUIDs appear nowhere in the catalog — add them to syntheticGuids only if they are deliberately synthetic: \(unknown.sorted())")
    }
}

/// The inverse of the checks above.
///
/// `registeredGuidsAreReal` proves every *registered* GUID exists in the catalog. This proves the
/// other direction: every block class that declares a **real Dirigo GUID** is actually reachable
/// from the registry. A class whose GUID is real but which no factory builds is a block type that
/// compiles, appears in the source, and silently resolves to nothing when a project uses it —
/// which is exactly the failure the round-16 `GUID_PLACEHOLDER` incident would have produced had
/// the GUID been plausible rather than obviously fake.
@Suite("Block class reachability")
struct BlockClassReachabilityTests {
    static var librarySources: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: BlockSourceIdentityTests.libraryDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Class name → the GUID literal it declares, for every `public final class` in the library.
    static func declaredGuid(of source: String, className: String) -> String? {
        guard let classRange = source.range(of: "public final class \(className)") else { return nil }
        let tail = source[classRange.upperBound...]
        // The static sits at the top of the class; stop before the next class declaration.
        let end = tail.range(of: "public final class")?.lowerBound ?? tail.endIndex
        guard let guid = tail[..<end].range(of: "uuidString: \"") else { return nil }
        let after = tail[guid.upperBound...]
        guard let close = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<close])
    }

    @Test("Every block class with a real GUID is registered")
    func noOrphanedRealGuids() {
        let catalog = Set(BlockTypeCatalog.all.map { $0.guid.uuidString.uppercased() })
        let registered = Set(BlockRegistry.shared.registeredGuids.map { $0.uuidString.uppercased() })
        let synthetic = Set(BlockSourceIdentityTests.syntheticGuids.map { $0.uppercased() })

        var orphaned: [String] = []
        for file in Self.librarySources where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var rest = Substring(text)
            while let decl = rest.range(of: "public final class ") {
                let after = rest[decl.upperBound...]
                let name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                rest = after
                guard !name.isEmpty, let guid = Self.declaredGuid(of: text, className: name) else { continue }
                let upper = guid.uppercased()
                // Synthetic classes are never used for dispatch, so they are exempt by design.
                guard !synthetic.contains(upper), catalog.contains(upper) else { continue }
                if !registered.contains(upper) {
                    orphaned.append("\(name) declares \(upper), which no factory registers")
                }
            }
        }
        #expect(orphaned.isEmpty, "block classes that a project could never resolve: \(orphaned.sorted())")
    }
}

/// The catalog's `isImplemented` flag is the machine-readable answer to "does this build support
/// this block type", and it is what the coverage documents were derived from. A stale `false` on a
/// type that *is* implemented understates the port and sends anyone reading it looking for work
/// that is already done — 57 types were in that state when this test was written.
@Suite("Catalog implementation flags")
struct CatalogFlagTests {
    @Test("Every registered type is marked implemented")
    func registeredTypesAreFlagged() {
        // Shape-only by design: the help has no entry for `Switch2`, so its semantics are not
        // implemented even though the type resolves and its pins are correct.
        let shapeOnly: Set<String> = ["Switch2"]
        // The engine's own fallbacks, not Dirigo module types.
        let engineInternal: Set<String> = ["Generic", "Unresolved"]

        let registered = Set(BlockRegistry.shared.registeredGuids.map { $0.uuidString.uppercased() })
        let stale = BlockTypeCatalog.all
            .filter { registered.contains($0.guid.uuidString.uppercased()) && !$0.isImplemented }
            .map(\.blockName)
            .filter { !shapeOnly.contains($0) && !engineInternal.contains($0) }
        #expect(stale.isEmpty, "these are registered but still flagged unimplemented: \(stale.sorted())")
    }

    @Test("The shape-only list has no stale entries")
    func shapeOnlyIsAccurate() {
        let registered = Set(BlockRegistry.shared.registeredGuids.map { $0.uuidString.uppercased() })
        let nowImplemented = BlockTypeCatalog.all
            .filter { ["Switch2"].contains($0.blockName) && $0.isImplemented && registered.contains($0.guid.uuidString.uppercased()) }
            .map(\.blockName)
        #expect(nowImplemented.isEmpty, "these now have semantics — remove them from shapeOnly: \(nowImplemented)")
    }
}
