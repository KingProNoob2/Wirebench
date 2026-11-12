import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary

/// Dirigo reads every coordinate with `StrToInt`, so a fractional one makes it refuse the whole file: "is not a valid
/// integer value". The model keeps points as `Double` for the canvas; the file gets whole numbers.
@Suite("Coordinates in the .pcc")
struct SerializerCoordinateTests {
    @Test("Module and wire coordinates are written as whole numbers")
    func wholeNumbers() throws {
        var project = PCCProject(name: "P", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        let module = BlockFactory.makeModule(guid: AndBlock.guid, id: 1, name: "And1",
                                             x: 12.5, y: -3.2, order: 10, threadId: 1, page: "main")
        project.modules = [module]
        project.inConnections = [Connection(inModuleId: 1, inPinId: 1, outModuleId: 1, outPinId: 0,
                                            nameX: 4.4, nameY: -1.5)]
        let xml = PCCSerializer().serialize(project: project)
        #expect(xml.contains("X=\"13\""))
        #expect(xml.contains("Y=\"-3\""))
        #expect(!xml.contains("12.5"))
        #expect(xml.contains("NAME_X=\"4\""))
        #expect(xml.contains("NAME_Y=\"-2\""))
    }

    @Test("A file Dirigo wrote keeps its coordinates byte for byte")
    func fixtureUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kostka-1.pcc")
        let original = try String(contentsOf: url, encoding: .utf8)
        let project = try PCCParser().parse(xmlString: original)
        #expect(PCCSerializer().serialize(project: project) == original)
    }
}
