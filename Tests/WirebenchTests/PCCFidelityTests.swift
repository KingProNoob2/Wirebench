import Testing
import Foundation
@testable import WirebenchCore

/// Round-trip fidelity tests against the genuine Dirigo-saved projects in the repository.
///
/// `rulkoshaddirigo.pcc` and its two `__history` snapshots are the only files in this workspace
/// that were written by Dirigo itself. (`ruleta_kostka_had.pcc` is *not* — it is single-line and
/// carries `COLOR="/bin/zsh"` where a colour value belongs, so it is a synthetic file produced
/// by earlier tooling. It is deliberately excluded from the byte-exact assertions.)
@Suite("PCC round-trip fidelity")
struct PCCFidelityTests {
    static let workspace = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WirebenchTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Wirebench
        .deletingLastPathComponent()   // workspace root

    /// Every pristine Dirigo-saved project we have.
    static var pristineProjects: [URL] {
        var urls: [URL] = [workspace.appendingPathComponent("rulkoshaddirigo.pcc")]
        let history = workspace.appendingPathComponent("__history")
        if let entries = try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: entries.filter { $0.lastPathComponent.hasSuffix(".pcc.~1~") || $0.lastPathComponent.hasSuffix(".pcc.~2~") })
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
    }

    /// Reports the first differing byte with surrounding context — far more useful than a bare
    /// "strings are not equal".
    static func describeDifference(_ expected: String, _ actual: String) -> String {
        if expected == actual { return "identical" }
        let e = Array(expected.unicodeScalars)
        let a = Array(actual.unicodeScalars)
        var i = 0
        while i < min(e.count, a.count), e[i] == a[i] { i += 1 }
        func lineContext(_ scalars: [UnicodeScalar], upTo offset: Int) -> (Int, String) {
            let head = scalars[0..<min(offset, scalars.count)]
            let line = head.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1
            let start = head.lastIndex(of: "\n").map { $0 + 1 } ?? 0
            var end = min(offset, scalars.count)
            while end < scalars.count, scalars[end] != "\n" { end += 1 }
            return (line, String(String.UnicodeScalarView(scalars[start..<end])))
        }
        let (eLine, eText) = lineContext(e, upTo: i)
        let (aLine, aText) = lineContext(a, upTo: i)
        return """
        first difference at scalar offset \(i) (expected \(e.count) scalars, got \(a.count))
          expected line \(eLine): \(eText)
          actual   line \(aLine): \(aText)
        """
    }

    /// Decodes numeric character references and drops whitespace that is not inside a quoted
    /// attribute value, so two documents compare equal iff they carry the same content. This is
    /// what lets us assert "nothing was lost" even for files written by an older Dirigo whose
    /// pretty-printer and entity spelling differ from the current one.
    static func canonical(_ xml: String) -> String {
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

    /// Files written by the current Dirigo writer, whose exact formatting we reproduce.
    static let byteExactProjects = ["rulkoshaddirigo.pcc", "rulkoshaddirigo.pcc.~2~"]

    /// `rulkoshaddirigo.pcc.~1~` was written by an older Dirigo build that laid long runs of
    /// siblings out on a single line and spelled character references zero-padded (`&#09;`).
    /// The content still round-trips exactly; only that whitespace/spelling differs.
    static let knownLegacyFormatting = ["rulkoshaddirigo.pcc.~1~"]

    @Test("Pristine projects round-trip with no content change")
    func contentRoundTrip() throws {
        let parser = PCCParser()
        let serializer = PCCSerializer()
        let projects = Self.pristineProjects
        #expect(!projects.isEmpty, "no pristine Dirigo projects found")

        var notByteExact: [String] = []
        for url in projects {
            let name = url.lastPathComponent
            let original = try String(contentsOf: url, encoding: .utf8)
            let reEmitted = serializer.serialize(project: try parser.parse(fileAt: url))

            if original == reEmitted { continue }
            notByteExact.append(name)

            let a = Self.canonical(original)
            let b = Self.canonical(reEmitted)
            if a != b {
                Issue.record("\(name): content changed on round trip\n  \(Self.describeDifference(a, b))")
            }
        }

        // Byte-exact output is guaranteed for current-format projects. If this list grows, a
        // formatting regression has been introduced.
        let expectedLegacy = Self.knownLegacyFormatting.sorted()
        #expect(notByteExact.sorted() == expectedLegacy,
                "unexpected set of projects that are not byte-exact: \(notByteExact.sorted())")
    }

    @Test("Current-format projects are byte-for-byte identical after a round trip")
    func byteExactRoundTrip() throws {
        let parser = PCCParser()
        let serializer = PCCSerializer()
        for url in Self.pristineProjects where Self.byteExactProjects.contains(url.lastPathComponent) {
            let original = try String(contentsOf: url, encoding: .utf8)
            let reEmitted = serializer.serialize(project: try parser.parse(fileAt: url))
            if original != reEmitted {
                Issue.record("\(url.lastPathComponent): \(Self.describeDifference(original, reEmitted))")
            }
        }
    }

    @Test("The synthetic corpus also round-trips without content change")
    func syntheticCorpusContentRoundTrip() throws {
        // `ruleta_kostka_had.pcc` was not written by Dirigo, but it exercises more block types
        // than the pristine project, so it is still worth checking that a save loses nothing.
        let url = Self.workspace.appendingPathComponent("ruleta_kostka_had.pcc")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let original = try String(contentsOf: url, encoding: .utf8)
        let reEmitted = PCCSerializer().serialize(project: try PCCParser().parse(fileAt: url))
        let before = Self.canonical(original)
        let after = Self.canonical(reEmitted)
        if before != after {
            let detail = Self.describeDifference(before, after)
            Issue.record("\(detail)")
        }
    }

    @Test("Serialising is idempotent")
    func idempotent() throws {
        let parser = PCCParser()
        let serializer = PCCSerializer()
        for url in Self.pristineProjects {
            let first = serializer.serialize(project: try parser.parse(fileAt: url))
            let second = serializer.serialize(project: try parser.parse(xmlString: first))
            #expect(first == second, "\(url.lastPathComponent) is not a serialisation fixpoint")
        }
    }

    @Test("No attribute is lost or invented on a round trip")
    func attributeSetPreserved() throws {
        let parser = PCCParser()
        let serializer = PCCSerializer()
        for url in Self.pristineProjects {
            let before = try parser.parse(fileAt: url)
            let xml = serializer.serialize(project: before)
            let after = try parser.parse(xmlString: xml)

            #expect(before.sectionOrder == after.sectionOrder, "\(url.lastPathComponent): section order changed")
            #expect(before.rawAttributes.keys == after.rawAttributes.keys, "\(url.lastPathComponent): root attributes changed")
            #expect(before.rawSections == after.rawSections, "\(url.lastPathComponent): unmodelled sections changed")

            #expect(before.modules.count == after.modules.count)
            for (lhs, rhs) in zip(before.modules, after.modules) {
                #expect(lhs.rawAttributes.keys == rhs.rawAttributes.keys,
                        "\(lhs.name): module attribute set changed\n  \(lhs.rawAttributes.keys)\n  \(rhs.rawAttributes.keys)")
                #expect(lhs.inPins.map(\.rawAttributes.keys) == rhs.inPins.map(\.rawAttributes.keys),
                        "\(lhs.name): input pin attribute sets changed")
                #expect(lhs.paramPins.map(\.rawAttributes.keys) == rhs.paramPins.map(\.rawAttributes.keys),
                        "\(lhs.name): param pin attribute sets changed")
                #expect(lhs.outPins.map(\.rawAttributes.keys) == rhs.outPins.map(\.rawAttributes.keys),
                        "\(lhs.name): output pin attribute sets changed")
                #expect(lhs.inPins.compactMap(\.name) == rhs.inPins.compactMap(\.name),
                        "\(lhs.name): input pin names changed")
                #expect(lhs.outPins.compactMap(\.name) == rhs.outPins.compactMap(\.name),
                        "\(lhs.name): output pin names changed")
            }

            #expect(before.graphics.count == after.graphics.count)
            for (lhs, rhs) in zip(before.graphics, after.graphics) {
                #expect(lhs.rawChildren == rhs.rawChildren, "graphic subtree changed")
            }
        }
    }

    @Test("Pin names and display formats are read from the real attribute names")
    func pinNamesAreParsed() throws {
        let url = Self.workspace.appendingPathComponent("rulkoshaddirigo.pcc")
        let project = try PCCParser().parse(fileAt: url)

        // Macro invocation: named inputs, no outputs.
        let had = try #require(project.modules.first { $0.name == "had1" })
        #expect(had.inPins.compactMap(\.name) == ["Inp1"])
        #expect(had.outPins.isEmpty)

        // Macro interface: named outputs only.
        let inputs = try #require(project.modules.first { $0.name == "Inputs1" })
        #expect(inputs.outPins.compactMap(\.name) == ["Inp1", "Inp2"])
        #expect(inputs.rawAttributes["MACRO_NAME"] == "Inputs")
        #expect(inputs.rawAttributes["KIND"] == "0")

        // The Value display block carries its presentation attributes.
        let active = try #require(project.modules.first { $0.name == "AktivniRezim" })
        #expect(active.rawAttributes["WIDTH"] == "100")
        #expect(active.rawAttributes["LIMIT"] == "1")
    }

    @Test("Re-emitting a project preserves macro wiring definitions")
    func macroDefinitionsSurvive() throws {
        let url = Self.workspace.appendingPathComponent("rulkoshaddirigo.pcc")
        let parser = PCCParser()
        let serializer = PCCSerializer()

        let before = try parser.parse(fileAt: url)
        let after = try parser.parse(xmlString: serializer.serialize(project: before))

        let beforeMacros = before.modules.compactMap { $0.rawAttributes["MACRO_NAME"] }.sorted()
        let afterMacros = after.modules.compactMap { $0.rawAttributes["MACRO_NAME"] }.sorted()
        #expect(!beforeMacros.isEmpty)
        #expect(beforeMacros == afterMacros)

        let beforeKinds = before.modules.compactMap { $0.rawAttributes["KIND"] }.sorted()
        let afterKinds = after.modules.compactMap { $0.rawAttributes["KIND"] }.sorted()
        #expect(beforeKinds == afterKinds)
    }
}
