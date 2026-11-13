import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// Opening a Maraflow `.mfl`: Java properties XML, its block definitions and wires.
@Suite("Maraflow import")
struct MaraflowImportTests {
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func propertiesXML(_ entries: [(String, String)]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
        <properties>
        <comment>Maraflow PLC Project (.mfl)</comment>
        """
        for (key, value) in entries {
            xml += "<entry key=\"\(escape(key))\">\(escape(value))</entry>\n"
        }
        xml += "</properties>\n"
        return Data(xml.utf8)
    }

    static func block(_ prefix: String, id: String, definition: String, type: String, name: String,
                      gridX: Int, gridY: Int, order: Int,
                      inputs: [(String, String, String, String)], outputs: [(String, String, String, String)]) -> [(String, String)] {
        var entries: [(String, String)] = [
            (prefix + "id", id),
            (prefix + "defId", definition),
            (prefix + "typeName", type),
            (prefix + "name", name),
            (prefix + "gridX", "\(gridX)"),
            (prefix + "gridY", "\(gridY)"),
            (prefix + "threadId", "2"),
            (prefix + "order", "\(order)"),
            (prefix + "color", "clDefault"),
            (prefix + "description", ""),
            (prefix + "propCount", "0"),
            (prefix + "inCount", "\(inputs.count)"),
            (prefix + "outCount", "\(outputs.count)"),
        ]
        for (index, pin) in inputs.enumerated() {
            entries.append((prefix + "in.\(index).short", pin.0))
            entries.append((prefix + "in.\(index).full", pin.1))
            entries.append((prefix + "in.\(index).type", pin.2))
            entries.append((prefix + "in.\(index).const", pin.3))
        }
        for (index, pin) in outputs.enumerated() {
            entries.append((prefix + "out.\(index).short", pin.0))
            entries.append((prefix + "out.\(index).full", pin.1))
            entries.append((prefix + "out.\(index).type", pin.2))
            entries.append((prefix + "out.\(index).const", pin.3))
        }
        return entries
    }

    static func demoProject() -> Data {
        var entries: [(String, String)] = [
            ("maraflow.version", "1.0.0"),
            ("project.name", "Demo"),
            ("project.author", "Mat"),
            ("project.description", "Import test"),
            ("project.targetPlatform", "STM32F407-Maraflow-Std"),
            ("project.defaultThreadId", "2"),
            ("project.primaryLanguage", "FBD"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "5"),
            ("page.0.wireCount", "5"),
            ("page.0.graphicCount", "0"),
            ("page.0.rungCount", "0"),
        ]
        entries += block("page.0.block.0.", id: "a", definition: "Bool.And", type: "And", name: "And1",
                         gridX: 2, gridY: 3, order: 10,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("X1", "Input 1", "BOOL", "1"),
                                  ("X2", "Input 2", "BOOL", "0")],
                         outputs: [("Y", "Logical Output", "BOOL", "0")])
        entries += block("page.0.block.1.", id: "b", definition: "Bool.Not", type: "Not", name: "Not1",
                         gridX: 8, gridY: 3, order: 20,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("X", "Input", "BOOL", "0")],
                         outputs: [("Y", "Inverted Output", "BOOL", "0")])
        entries += block("page.0.block.2.", id: "c", definition: "IO.8xDO", type: "8x DO", name: "8xDO1",
                         gridX: 16, gridY: 3, order: 30,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("DO0", "Digital Output 0", "BOOL", "0"),
                                  ("DO1", "Digital Output 1", "BOOL", "0"),
                                  ("DO2", "Digital Output 2", "BOOL", "0")],
                         outputs: [("Ok", "Port Write Status", "BOOL", "1")])
        entries += block("page.0.block.3.", id: "d", definition: "Math.PID", type: "PID", name: "PID1",
                         gridX: 24, gridY: 3, order: 40,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("PV", "Process Variable", "FLOAT", "0"),
                                  ("SP", "Setpoint", "FLOAT", "0"),
                                  ("Kp", "Proportional Gain", "FLOAT", "1"),
                                  ("Ki", "Integral Gain", "FLOAT", "0"),
                                  ("Kd", "Derivative Gain", "FLOAT", "0"),
                                  ("Rst", "Reset Integrator", "BOOL", "0")],
                         outputs: [("Out", "Controller Output", "FLOAT", "0")])
        entries += block("page.0.block.4.", id: "e", definition: "Bool.Nand", type: "Nand", name: "Nand1",
                         gridX: 2, gridY: 9, order: 50,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("X1", "Input 1", "BOOL", "1"),
                                  ("X2", "Input 2", "BOOL", "1")],
                         outputs: [("Y", "Logical Output", "BOOL", "0")])
        entries += [
            ("page.0.wire.0.srcBlock", "a"), ("page.0.wire.0.srcPin", "0"),
            ("page.0.wire.0.dstBlock", "b"), ("page.0.wire.0.dstPin", "1"),
            ("page.0.wire.1.srcBlock", "b"), ("page.0.wire.1.srcPin", "0"),
            ("page.0.wire.1.dstBlock", "c"), ("page.0.wire.1.dstPin", "1"),
            ("page.0.wire.2.srcBlock", "a"), ("page.0.wire.2.srcPin", "0"),
            ("page.0.wire.2.dstBlock", "d"), ("page.0.wire.2.dstPin", "1"),
            ("page.0.wire.3.srcBlock", "d"), ("page.0.wire.3.srcPin", "0"),
            ("page.0.wire.3.dstBlock", "c"), ("page.0.wire.3.dstPin", "2"),
            ("page.0.wire.4.srcBlock", "e"), ("page.0.wire.4.srcPin", "0"),
            ("page.0.wire.4.dstBlock", "c"), ("page.0.wire.4.dstPin", "3"),
        ]
        return propertiesXML(entries)
    }

    @Test("A Maraflow sheet imports with mapped blocks, placeholders and wires")
    func importDemo() throws {
        let data = Self.demoProject()
        let loaded = try ProjectFile.read(data: data, filename: "demo")
        #expect(loaded.format == .maraflow)
        let project = loaded.project
        #expect(project.pages.map(\.caption) == ["Main"])
        #expect(project.modules.count == 5)
        #expect(loaded.notes.first?.contains("Imported 1 page") == true)

        let and = try #require(project.modules.first { $0.name == "And1" })
        #expect(and.guid == BlockTypeCatalog.info(forBlockName: "And")?.guid)
        #expect(and.x == 64 && and.y == 96)
        #expect(and.inPins[0].value == .bool(true))
        #expect(and.inPins[1].value == .bool(true))
        #expect(and.inPins[2].value == .bool(false))

        let not = try #require(project.modules.first { $0.name == "Not1" })
        let andToNot = try #require(project.connection(inModuleId: not.id, inPinId: 1))
        #expect(andToNot.outModuleId == and.id && andToNot.outPinId == 0)

        let output = try #require(project.modules.first { $0.name == "8xDO1" })
        #expect(output.guid == BlockTypeCatalog.info(forBlockName: "8xDO")?.guid)
        #expect(output.inPins.count == 9)
        #expect(project.connection(inModuleId: output.id, inPinId: 1)?.outModuleId == not.id)
        #expect(project.connection(inModuleId: output.id, inPinId: 2)?.outModuleId != nil)

        // Nand is mapped to And with its output inverted at the consumer.
        #expect(output.inPins[3].inverted)

        let placeholder = try #require(project.modules.first { $0.name == "PID1" })
        #expect(placeholder.guid == BlockTypeCatalog.info(forBlockName: "Unresolved")?.guid)
        #expect(placeholder.inPins.count == 7)
        #expect(placeholder.outPins.count == 1)
        #expect(loaded.notes.contains { $0.contains("PID") && $0.contains("placeholder") })
        #expect(project.connection(inModuleId: output.id, inPinId: 2)?.outModuleId == placeholder.id)

        // Everything that was imported survives the native format.
        let encoded = try WirebenchDocument.encode(project)
        #expect(try WirebenchDocument.decode(encoded) == project)
    }

    @Test("The app opens .mfl as an imported project and saves it as .wbp")
    @MainActor
    func appImport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maraflow-\(UUID()).mfl")
        try Self.demoProject().write(to: url)
        let model = AppModel()
        model.loadProject(url: url)
        #expect(model.isLegacyDocument, "an imported project is saved under a new name")
        #expect(model.project?.modules.count == 5)
        #expect(model.saveAsDefaultName == url.deletingPathExtension().lastPathComponent)
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("maraflow-\(UUID()).wbp")
        try model.saveProject(to: saved)
        #expect(!model.isLegacyDocument)
        let reopened = AppModel()
        reopened.loadProject(url: saved)
        #expect(reopened.project?.modules.count == 5)
    }

    @Test("ST, ladder and macro pages are kept with their limits reported")
    func nonFBDPages() throws {
        let entries: [(String, String)] = [
            ("project.name", "Mixed"),
            ("project.pageCount", "3"),
            ("page.0.name", "Code"),
            ("page.0.language", "ST"),
            ("page.0.stCode", "VAR x : BOOL; END_VAR x := TRUE;"),
            ("page.0.stVarCount", "1"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Relays"),
            ("page.1.language", "LD"),
            ("page.1.rungCount", "2"),
            ("page.1.blockCount", "0"),
            ("page.1.wireCount", "0"),
            ("page.2.name", "*Blink"),
            ("page.2.language", "FBD"),
            ("page.2.blockCount", "0"),
            ("page.2.wireCount", "0"),
        ]
        let loaded = try ProjectFile.read(data: Self.propertiesXML(entries), filename: "mixed")
        #expect(loaded.format == .maraflow)
        #expect(loaded.project.pages.map(\.caption) == ["Code", "Relays", "Blink"])
        let notes = loaded.notes.joined(separator: "\n")
        #expect(notes.contains("Structured Text"))
        #expect(notes.contains("ladder rung"))
        #expect(notes.contains("Macro page"))
        #expect(loaded.project.modules.isEmpty)
    }

    @Test("A non-Maraflow XML file is not treated as one")
    func notMaraflow() throws {
        let data = Data("<not-a-project/>".utf8)
        #expect(throws: (any Error).self) {
            try ProjectFile.read(data: data)
        }
    }
}
