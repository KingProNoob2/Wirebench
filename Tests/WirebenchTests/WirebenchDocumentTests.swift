import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchModel

/// The on-disk format: a versioned JSON envelope around the project, with attribute and section order preserved for
/// the legacy export.
@Suite("Wirebench document")
struct WirebenchDocumentTests {
    static func richProject() -> PCCProject {
        var project = BlockDeletionTests.project()
        project.rawAttributes = AttributeBag([("APP", "Wirebench"), ("Z_LAST", "1")])
        project.rawSections = [RawXMLNode(name: "CONSTANTS", attributes: AttributeBag([("NAME", "K")]),
                                          children: [RawXMLNode(name: "ITEM")])]
        project.rootComments = [RawXMLNode(name: "#comment", attributes: AttributeBag([("TEXT", "keep me")]))]
        project.selfClosingSpace = true
        project.modules[0].rawAttributes = AttributeBag([("SHOW_COUNT", "true")])
        project.modules[0].rawChildren = [RawXMLNode(name: "CUSTOM", attributes: AttributeBag([("X", "1")]))]
        project.modules[0].inPins[0] = Pin(id: 0, value: .int32(7), inverted: true, rights: 0,
                                           name: "custom", format: "%d",
                                           rawAttributes: AttributeBag([("LABEL", "A")]))
        return project
    }

    @Test("A project round-trips through the JSON format unchanged")
    func roundTrip() throws {
        let project = Self.richProject()
        let data = try WirebenchDocument.encode(project)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"format\" : \"wirebench-project\""))
        #expect(text.contains("\"formatVersion\" : 1"))
        #expect(text.hasSuffix("\n"))
        let decoded = try WirebenchDocument.decode(data)
        #expect(decoded == project)
        #expect(decoded.rawAttributes.keys == ["APP", "Z_LAST"], "attribute order survives")
        #expect(decoded.modules[0].inPins[0].rawAttributes.keys == ["LABEL"])
        #expect(decoded.selfClosingSpace)
    }

    @Test("Unknown fields are ignored, so the format can grow additively")
    func unknownFieldsAreIgnored() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: WirebenchDocument.encode(Self.richProject()))
                                  as? [String: Any])
        object["futureField"] = ["anything": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try WirebenchDocument.decode(data) == Self.richProject())
    }

    @Test("A newer format version is refused with its number")
    func newerVersionIsRefused() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: WirebenchDocument.encode(Self.richProject()))
                                  as? [String: Any])
        object["formatVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: WirebenchDocumentError.unsupportedVersion(2)) {
            try WirebenchDocument.decode(data)
        }
    }

    @Test("Another JSON format and a non-document are refused")
    func foreignAndGarbageAreRefused() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: WirebenchDocument.encode(Self.richProject()))
                                  as? [String: Any])
        object["format"] = "some-other-editor"
        let foreign = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: WirebenchDocumentError.foreignFormat("some-other-editor")) {
            try WirebenchDocument.decode(foreign)
        }
        #expect(throws: WirebenchDocumentError.self) {
            try WirebenchDocument.decode(Data("<PCC_PROJECT/>".utf8))
        }
        #expect(!WirebenchDocument.looksLikeDocument(Data("  <PCC_PROJECT/>".utf8)))
        #expect(WirebenchDocument.looksLikeDocument(Data("\n {\"format\": \"wirebench-project\"}".utf8)))
    }

    @MainActor
    @Test("The app saves .wbp and imports a legacy .pcc as read-only")
    func appModelSavesCurrentFormat() throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-open-\(UUID()).pcc")
        try PCCSerializer().serialize(project: BlockDeletionTests.project())
            .write(to: legacyURL, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: legacyURL)
        #expect(model.isLegacyDocument)
        #expect(model.saveAsDefaultName == legacyURL.deletingPathExtension().lastPathComponent)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-\(UUID()).wbp")
        try model.saveProject(to: output)
        #expect(!model.isLegacyDocument)
        #expect(model.currentFileURL == output)
        #expect(try String(contentsOf: output, encoding: .utf8).hasPrefix("{"))

        let reopened = AppModel()
        reopened.loadProject(url: output)
        #expect(!reopened.isLegacyDocument)
        #expect(reopened.project == model.project)
    }

    @Test("ProjectFile opens both formats and writes the current one")
    func projectFileReadsBothFormats() throws {
        let project = Self.richProject()
        let plain = BlockDeletionTests.project()
        let directory = FileManager.default.temporaryDirectory
        let legacy = directory.appendingPathComponent("legacy-\(UUID().uuidString).pcc")
        let current = directory.appendingPathComponent("current-\(UUID().uuidString).wbp")
        try PCCSerializer().serialize(project: plain).write(to: legacy, atomically: true, encoding: .utf8)
        try ProjectFile.write(project, to: current)

        let old = try ProjectFile.read(at: legacy)
        #expect(old.format == .dirigo)
        #expect(old.project.name == plain.name)

        let new = try ProjectFile.read(at: current)
        #expect(new.format == .wirebench)
        #expect(new.project == project)
        #expect(try String(contentsOf: current, encoding: .utf8).hasPrefix("{"))
    }
}
