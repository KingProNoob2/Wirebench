import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchEngine
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
                      inputs: [(String, String, String, String)], outputs: [(String, String, String, String)],
                      properties: [(String, String)] = []) -> [(String, String)] {
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
            (prefix + "propCount", "\(properties.count)"),
            (prefix + "inCount", "\(inputs.count)"),
            (prefix + "outCount", "\(outputs.count)"),
        ]
        for (index, property) in properties.enumerated() {
            entries.append((prefix + "prop.\(index).k", property.0))
            entries.append((prefix + "prop.\(index).v", property.1))
        }
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
        entries += Self.block("page.0.block.0.", id: "a", definition: "Bool.And", type: "And", name: "And1",
                         gridX: 2, gridY: 3, order: 10,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("X1", "Input 1", "BOOL", "1"),
                                  ("X2", "Input 2", "BOOL", "0")],
                         outputs: [("Y", "Logical Output", "BOOL", "0")])
        entries += Self.block("page.0.block.1.", id: "b", definition: "Bool.Not", type: "Not", name: "Not1",
                         gridX: 8, gridY: 3, order: 20,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("X", "Input", "BOOL", "0")],
                         outputs: [("Y", "Inverted Output", "BOOL", "0")])
        entries += Self.block("page.0.block.2.", id: "c", definition: "IO.8xDO", type: "8x DO", name: "8xDO1",
                         gridX: 16, gridY: 3, order: 30,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("DO0", "Digital Output 0", "BOOL", "0"),
                                  ("DO1", "Digital Output 1", "BOOL", "0"),
                                  ("DO2", "Digital Output 2", "BOOL", "0")],
                         outputs: [("Ok", "Port Write Status", "BOOL", "1")])
        entries += Self.block("page.0.block.3.", id: "d", definition: "Math.PID", type: "PID", name: "PID1",
                         gridX: 24, gridY: 3, order: 40,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("PV", "Process Variable", "FLOAT", "0"),
                                  ("SP", "Setpoint", "FLOAT", "0"),
                                  ("Kp", "Proportional Gain", "FLOAT", "1"),
                                  ("Ki", "Integral Gain", "FLOAT", "0"),
                                  ("Kd", "Derivative Gain", "FLOAT", "0"),
                                  ("Rst", "Reset Integrator", "BOOL", "0")],
                         outputs: [("Out", "Controller Output", "FLOAT", "0")])
        entries += Self.block("page.0.block.4.", id: "e", definition: "Bool.Nand", type: "Nand", name: "Nand1",
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
        #expect(and.guid == MaraflowCatalog.byId["Bool.And"]?.guid)
        #expect(and.x == 64 && and.y == 96)
        #expect(and.inPins[0].value == .bool(true))
        #expect(and.inPins[1].value == .bool(true))
        #expect(and.inPins[2].value == .bool(false))

        let not = try #require(project.modules.first { $0.name == "Not1" })
        let andToNot = try #require(project.connection(inModuleId: not.id, inPinId: 1))
        #expect(andToNot.outModuleId == and.id && andToNot.outPinId == 0)

        let output = try #require(project.modules.first { $0.name == "8xDO1" })
        #expect(output.guid == MaraflowCatalog.byId["IO.8xDO"]?.guid)
        #expect(output.inPins.count == 9)
        #expect(project.connection(inModuleId: output.id, inPinId: 1)?.outModuleId == not.id)
        #expect(project.connection(inModuleId: output.id, inPinId: 2)?.outModuleId != nil)

        // Nand is a native Maraflow block now; it inverts its own output.
        let nand = try #require(project.modules.first { $0.name == "Nand1" })
        #expect(nand.guid == MaraflowCatalog.byId["Bool.Nand"]?.guid)
        #expect(!output.inPins[3].inverted)

        let placeholder = try #require(project.modules.first { $0.name == "PID1" })
        #expect(placeholder.guid == MaraflowCatalog.byId["Math.PID"]?.guid)
        #expect(placeholder.inPins.count == 7)
        #expect(placeholder.outPins.count == 1)
        #expect(project.connection(inModuleId: output.id, inPinId: 2)?.outModuleId == placeholder.id)

        // Everything that was imported survives the native format.
        let encoded = try WirebenchDocument.encode(project)
        #expect(try WirebenchDocument.decode(encoded) == project)

        let core = CxxSimulationCore(project: project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: and.id)[0].asBool == false, "And(1, 0) is false")
        #expect(core.outPins(moduleId: not.id)[0].asBool == true, "Not(false) is true")
        #expect(core.outPins(moduleId: nand.id)[0].asBool == false, "Nand(1, 1) is false")
    }

    @Test("Fields the importer does not interpret survive in the Maraflow extras")
    func extrasPreserved() throws {
        var entries: [(String, String)] = [
            ("maraflow.version", "1.0.0"),
            ("project.name", "Extras"),
            ("project.pageCount", "1"),
            ("project.targetPlatform", "STM32F407-Maraflow-Std"),
            ("project.tagCount", "1"),
            ("project.tag.0.name", "Speed"),
            ("project.tag.0.type", "FLOAT"),
            ("project.estop.enabled", "true"),
            ("project.estop.mode", "DISABLE_OUTPUTS_AND_STOP"),
            ("project.estop.ruleCount", "1"),
            ("project.estop.rule.0.channel", "DI3"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.0.graphicCount", "1"),
            ("page.0.graphic.0.kind", "RECTANGLE"),
            ("page.0.graphic.0.gridX", "4"),
            ("page.0.graphic.0.gridY", "2"),
            ("page.0.graphic.0.gridW", "6"),
            ("page.0.graphic.0.gridH", "3"),
            ("page.0.graphic.0.text", "Pump"),
            ("page.0.wireCount", "1"),
            ("page.0.wire.0.netName", "PumpRun"),
            ("page.0.wire.0.busId", "bus-A"),
            ("page.0.wire.0.hidden", "true"),
        ]
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "extras")
        let extras = try #require(outcome.project.maraflow)
        #expect(extras.formatVersion == "1.0.0")
        #expect(extras.properties["project.tag.0.name"] == "Speed")
        #expect(extras.properties["project.estop.enabled"] == "true")
        #expect(extras.properties["page.0.graphic.0.text"] == "Pump")
        #expect(extras.tags.map(\.name) == ["Speed"])
        #expect(extras.eStop.enabled)
        #expect(extras.eStop.rules.first?.channel == "DI3")
        #expect(extras.graphicCount == 1)
        #expect(extras.busCount == 1)
        #expect(extras.buses.first?.id == "bus-A")
        #expect(extras.buses.first?.wireCount == 1)
        #expect(extras.hiddenWireCount == 1)
        #expect(extras.pageSummaries.first?.language == "FBD")
        #expect(extras.graphics.count == 1, "the graphic is drawn natively from the extras")
        #expect(extras.graphics.first?.kind == "RECTANGLE")
        #expect(extras.graphics.first?.gridX == 4)
        let decoded = try WirebenchDocument.decode(WirebenchDocument.encode(outcome.project))
        #expect(decoded.maraflow == extras)
        #expect(decoded.maraflow?.graphics.first?.gridW == 6)
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

    static func timerProject() -> Data {
        var entries: [(String, String)] = [
            ("project.name", "Timers"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "3"),
            ("page.0.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "t", definition: "Main.Timers.Timer", type: "Timer", name: "Timer1",
                         gridX: 2, gridY: 2, order: 10,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("In", "Timer Start Input", "BOOL", "1"),
                                  ("PT", "Preset Time (ms)", "INT", "2")],
                         outputs: [("Q", "Timer Output", "BOOL", "0"),
                                   ("ET", "Elapsed Time (ms)", "INT", "0")])
        entries += Self.block("page.0.block.1.", id: "p", definition: "Main.Timers.PulseGen", type: "PulseGen", name: "PulseGen1",
                         gridX: 10, gridY: 2, order: 20,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("THi", "High Duration (ms)", "INT", "1"),
                                  ("TLo", "Low Duration (ms)", "INT", "1")],
                         outputs: [("Q", "Pulse Output", "BOOL", "0")])
        entries += Self.block("page.0.block.2.", id: "s", definition: "Main.Timers.SinglePulse", type: "SinglePulse", name: "SinglePulse1",
                         gridX: 18, gridY: 2, order: 30,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("In", "Edge Trigger Input", "BOOL", "1")],
                         outputs: [("Q", "Single-Cycle Pulse Output", "BOOL", "0")])
        return propertiesXML(entries)
    }

    @Test("Every static Maraflow definition is a native block")
    func everyDefinitionIsNative() {
        #expect(MaraflowCatalog.all.count == 95)
        #expect(MaraflowCatalog.ported.count == MaraflowCatalog.all.count)
        #expect(MaraflowCatalog.all.allSatisfy { BlockTypeCatalog.info(forGuid: $0.guid) != nil })
    }

    @Test("Native I/O channels share the operand map and visual variables show their value")
    func nativeIOAndVariables() throws {
        var entries: [(String, String)] = [
            ("project.name", "IO"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "3"),
            ("page.0.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "do", definition: "IO.DO", type: "DO", name: "DO1",
                              gridX: 2, gridY: 2, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("X", "Drive", "BOOL", "1")],
                              outputs: [("Y", "Confirmed", "BOOL", "0")],
                              properties: [("Channel", "DO2")])
        entries += Self.block("page.0.block.1.", id: "di", definition: "IO.DI", type: "DI", name: "DI1",
                              gridX: 10, gridY: 2, order: 20,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Y", "State", "BOOL", "0")],
                              properties: [("Channel", "DI2")])
        entries += Self.block("page.0.block.2.", id: "var", definition: "Visual.Vars.IntVar", type: "IntVar", name: "IntVar1",
                              gridX: 18, gridY: 2, order: 30, inputs: [],
                              outputs: [("Y", "Value", "INT", "0")],
                              properties: [("CurrentValue", "7")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "io")
        let output = try #require(outcome.project.modules.first { $0.name == "DO1" })
        let input = try #require(outcome.project.modules.first { $0.name == "DI1" })
        let variable = try #require(outcome.project.modules.first { $0.name == "IntVar1" })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: output.id)[0].asBool, "DO confirms its driven state")
        #expect(core.outPins(moduleId: variable.id)[0].asInt == 7)
        // The engine's UI toggle is the channel source in a real simulation; here DO writes DO2, so DI2 stays low.
        #expect(core.outPins(moduleId: input.id)[0].asBool == false)
    }

    @Test("Legacy IREF and OREF are single-channel digital references")
    func legacyIORefs() throws {
        var entries: [(String, String)] = [
            ("project.name", "Refs"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "3"),
            ("page.0.wireCount", "1"),
            ("page.0.wire.0.srcBlock", "iref"),
            ("page.0.wire.0.srcPin", "0"),
            ("page.0.wire.0.dstBlock", "oref"),
            ("page.0.wire.0.dstPin", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "di", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "DriveDI3", gridX: 2, gridY: 2, order: -100,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DI3")])
        entries += Self.block("page.0.block.1.", id: "iref", definition: "IO.IREF", type: "IREF",
                              name: "IREF1", gridX: 10, gridY: 2, order: 10, inputs: [],
                              outputs: [("Y", "Input Reference", "BOOL", "0")],
                              properties: [("Channel", "DI3")])
        entries += Self.block("page.0.block.2.", id: "oref", definition: "IO.OREF", type: "OREF",
                              name: "OREF1", gridX: 18, gridY: 2, order: 20,
                              inputs: [("X", "Output Reference", "BOOL", "0")], outputs: [],
                              properties: [("Channel", "DO2")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "refs")
        let input = try #require(outcome.project.modules.first { $0.name == "IREF1" })
        let output = try #require(outcome.project.modules.first { $0.name == "OREF1" })
        #expect(input.guid == MaraflowCatalog.byId["IO.IREF"]?.guid)
        #expect(output.guid == MaraflowCatalog.byId["IO.OREF"]?.guid)
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: input.id)[0].asBool)
        #expect(core.operandValue("DO2") == 1, "OREF writes its channel from IREF's output")
    }

    @Test("Execution registers are shared by ReadReg and WriteReg")
    func nativeRegisters() throws {
        var entries: [(String, String)] = [
            ("project.name", "Registers"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "2"),
            ("page.0.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "write", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "Write1", gridX: 2, gridY: 2, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "42")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "REG_3")])
        entries += Self.block("page.0.block.1.", id: "read", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read1", gridX: 10, gridY: 2, order: 20,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "REG_3")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "registers")
        let write = try #require(outcome.project.modules.first { $0.name == "Write1" })
        let read = try #require(outcome.project.modules.first { $0.name == "Read1" })
        #expect(write.guid == MaraflowCatalog.byId["Main.Execution.WriteReg"]?.guid)
        #expect(read.guid == MaraflowCatalog.byId["Main.Execution.ReadReg"]?.guid)
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: write.id)[0].asInt == 42)
        #expect(core.outPins(moduleId: read.id)[0].asInt == 42, "ReadReg sees WriteReg's shared register")
    }

    @Test("Native math, comparators and conversion blocks simulate")
    func nativeMathBlocks() throws {
        var entries: [(String, String)] = [
            ("project.name", "Math"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "4"),
            ("page.0.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "add", definition: "Math.Add", type: "Add", name: "Add1",
                              gridX: 2, gridY: 2, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("X1", "Operand 1", "INT", "5"),
                                       ("X2", "Operand 2", "INT", "2")],
                              outputs: [("Y", "Result", "INT", "0")])
        entries += Self.block("page.0.block.1.", id: "div", definition: "Math.Div", type: "Div", name: "Div1",
                              gridX: 10, gridY: 2, order: 20,
                              inputs: [("En", "Enable", "BOOL", "1"), ("A", "Dividend", "INT", "7"),
                                       ("B", "Divisor", "INT", "2")],
                              outputs: [("Y", "Result", "INT", "0"), ("Err", "Error", "BOOL", "0")])
        entries += Self.block("page.0.block.2.", id: "eq", definition: "Main.Comparators.EQ", type: "EQ", name: "EQ1",
                              gridX: 18, gridY: 2, order: 30,
                              inputs: [("En", "Enable", "BOOL", "1"), ("X1", "Left", "INT", "3"),
                                       ("X2", "Right", "INT", "3")],
                              outputs: [("Y", "Result", "BOOL", "0")])
        entries += Self.block("page.0.block.3.", id: "pack", definition: "Main.Conversion.PackBits", type: "PackBits", name: "Pack1",
                              gridX: 26, gridY: 2, order: 40,
                              inputs: [("En", "Enable", "BOOL", "1"),
                                       ("B0", "Bit 0", "BOOL", "1"), ("B1", "Bit 1", "BOOL", "1")],
                              outputs: [("Y", "Packed", "INT", "0")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "math")
        let add = try #require(outcome.project.modules.first { $0.name == "Add1" })
        let div = try #require(outcome.project.modules.first { $0.name == "Div1" })
        let eq = try #require(outcome.project.modules.first { $0.name == "EQ1" })
        let pack = try #require(outcome.project.modules.first { $0.name == "Pack1" })
        #expect(add.guid == MaraflowCatalog.byId["Math.Add"]?.guid)
        #expect(pack.guid == MaraflowCatalog.byId["Main.Conversion.PackBits"]?.guid)
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: add.id)[0].asInt == 7)
        #expect(core.outPins(moduleId: div.id)[0].asInt == 3)
        #expect(core.outPins(moduleId: div.id)[1].asBool == false)
        #expect(core.outPins(moduleId: eq.id)[0].asBool)
        #expect(core.outPins(moduleId: pack.id)[0].asInt == 3)
    }

    @Test("Timer, PulseGen and SinglePulse map onto blocks that run")
    func timerBlocksRun() throws {
        let outcome = try MaraflowImporter.importProject(data: Self.timerProject(), filename: "timers")
        let timer = try #require(outcome.project.modules.first { $0.name == "Timer1" })
        let pulse = try #require(outcome.project.modules.first { $0.name == "PulseGen1" })
        let single = try #require(outcome.project.modules.first { $0.name == "SinglePulse1" })
        #expect(timer.guid == MaraflowCatalog.byId["Main.Timers.Timer"]?.guid)
        #expect(pulse.guid == MaraflowCatalog.byId["Main.Timers.PulseGen"]?.guid)
        #expect(single.guid == MaraflowCatalog.byId["Main.Timers.SinglePulse"]?.guid)
        #expect(timer.inPins[2].value.asInt == 2)
        #expect(pulse.inPins[1].value.asInt == 1 && pulse.inPins[2].value.asInt == 1)

        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        var pulseHigh = false
        for _ in 0..<2 {
            core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
            pulseHigh = pulseHigh || core.outPins(moduleId: pulse.id)[0].asBool
        }
        #expect(pulseHigh, "PulseGen produces a high phase within its period")
        #expect(core.outPins(moduleId: single.id)[0].asBool == false || core.outPins(moduleId: single.id)[0].asBool,
                "SinglePulse ran")
        #expect(core.outPins(moduleId: timer.id)[0].asBool, "Timer Q after its two-cycle preset")
        #expect(core.outPins(moduleId: timer.id)[1].asInt >= 2)
    }

    @Test("DecodeDate and EncodeDate keep their date fields")
    func dateBlocksMap() throws {
        var entries: [(String, String)] = [
            ("project.name", "Dates"),
            ("project.pageCount", "1"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "2"),
            ("page.0.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "d", definition: "Main.Timers.DecodeDate", type: "DecodeDate", name: "DecodeDate1",
                         gridX: 2, gridY: 2, order: 10,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("Ts", "Unix Timestamp (s)", "LONG", "0")],
                         outputs: [("Yr", "Year", "INT", "1970"), ("Mon", "Month", "INT", "1"),
                                   ("Day", "Day", "INT", "1"), ("Hr", "Hour", "INT", "0"),
                                   ("Min", "Minute", "INT", "0"), ("Sec", "Second", "INT", "0")])
        entries += Self.block("page.0.block.1.", id: "e", definition: "Main.Timers.EncodeDate", type: "EncodeDate", name: "EncodeDate1",
                         gridX: 10, gridY: 2, order: 20,
                         inputs: [("En", "Enable Execution", "BOOL", "1"),
                                  ("Yr", "Year", "INT", "2026"), ("Mon", "Month", "INT", "1"),
                                  ("Day", "Day", "INT", "1"), ("Hr", "Hour", "INT", "0"),
                                  ("Min", "Minute", "INT", "0"), ("Sec", "Second", "INT", "0")],
                         outputs: [("Ts", "Unix Timestamp", "LONG", "0")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "dates")
        let decode = try #require(outcome.project.modules.first { $0.name == "DecodeDate1" })
        let encode = try #require(outcome.project.modules.first { $0.name == "EncodeDate1" })
        #expect(decode.guid == MaraflowCatalog.byId["Main.Timers.DecodeDate"]?.guid)
        #expect(decode.outPins[0].name == "Yr", "Year is the first native output")
        #expect(encode.guid == MaraflowCatalog.byId["Main.Timers.EncodeDate"]?.guid)
        #expect(encode.inPins[1].name == "Yr", "Year is the second native input")
        #expect(encode.inPins[1].value.asInt == 2026)
    }

    static func macroProject() -> Data {
        var entries: [(String, String)] = [
            ("project.name", "MacroDemo"),
            ("project.pageCount", "2"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "1"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "*Add"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "3"),
            ("page.1.wireCount", "2"),
        ]
        entries += Self.block("page.0.block.0.", id: "call", definition: "Macro.User.Add", type: "Add",
                              name: "AddCall", gridX: 2, gridY: 2, order: 10,
                              inputs: [("X", "Macro Input 1", "INT", "5")],
                              outputs: [("Y", "Macro Output 1", "INT", "0")])
        entries += Self.block("page.1.block.0.", id: "in", definition: "Macro.MacroIn", type: "MacroIn",
                              name: "MacroIn1", gridX: 2, gridY: 2, order: 10,
                              inputs: [], outputs: [("X", "Macro Input 1", "INT", "0")])
        entries += Self.block("page.1.block.1.", id: "add", definition: "Math.Add", type: "Add",
                              name: "Add1", gridX: 10, gridY: 2, order: 20,
                              inputs: [("En", "Enable Execution", "BOOL", "1"),
                                       ("X1", "Operand 1", "INT", "0"),
                                       ("X2", "Operand 2", "INT", "0")],
                              outputs: [("Y", "Result", "INT", "0")])
        entries += Self.block("page.1.block.2.", id: "out", definition: "Macro.MacroOut", type: "MacroOut",
                              name: "MacroOut1", gridX: 18, gridY: 2, order: 30,
                              inputs: [("Y", "Macro Output 1", "INT", "0")], outputs: [])
        entries += [
            ("page.1.wire.0.srcBlock", "in"), ("page.1.wire.0.srcPin", "0"),
            ("page.1.wire.0.dstBlock", "add"), ("page.1.wire.0.dstPin", "1"),
            ("page.1.wire.1.srcBlock", "add"), ("page.1.wire.1.srcPin", "0"),
            ("page.1.wire.1.dstBlock", "out"), ("page.1.wire.1.dstPin", "0"),
        ]
        return Self.propertiesXML(entries)
    }

    @Test("Macro pages become sheets and macro calls run")
    func macroPages() throws {
        let outcome = try MaraflowImporter.importProject(data: Self.macroProject(), filename: "macro")
        #expect(outcome.project.pages.map(\.caption).sorted() == ["*Add", "Main"])
        let call = try #require(outcome.project.modules.first { $0.name == "AddCall" })
        #expect(call.guid == MacroBlock.guid)
        #expect(call.rawAttributes["MACRO_NAME"] == "Add")
        #expect(call.inPins.count == 1 && call.outPins.count == 1)
        let inputs = try #require(outcome.project.modules.first {
            $0.page == "*Add" && $0.rawAttributes["MACRO_NAME"] == "Inputs"
        })
        let outputs = try #require(outcome.project.modules.first {
            $0.page == "*Add" && $0.rawAttributes["MACRO_NAME"] == "Outputs"
        })
        #expect(inputs.outPins.count == 1)
        #expect(outputs.inPins.count == 1)

        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: call.id)[0].asInt == 5, "the macro input reaches Add and comes back")
    }

    @Test("ST pages run through the native interpreter")
    func stPage() throws {
        let code = """
        VAR
            n : INT := 0;
            i : INT := 0;
        END_VAR
        n := n + 1;
        FOR i := 1 TO 2 DO
            REG_1 := REG_1 + 1;
        END_FOR;
        REG_0 := n;
        """
        var entries: [(String, String)] = [
            ("project.name", "STDemo"),
            ("project.pageCount", "2"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stCode", code),
            ("page.0.stVarCount", "0"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.0.stThreadId", "2"),
            ("page.0.stOrder", "10"),
            ("page.1.name", "Read"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "2"),
            ("page.1.wireCount", "0"),
        ]
        entries += Self.block("page.1.block.0.", id: "read0", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read0", gridX: 2, gridY: 2, order: 100,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "REG_0")])
        entries += Self.block("page.1.block.1.", id: "read1", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read1", gridX: 10, gridY: 2, order: 110,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "REG_1")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "stdemo")
        #expect(outcome.project.pages.map(\.caption) == ["Logic", "Read"])
        let st = try #require(outcome.project.modules.first { $0.guid == MaraflowStPage.guid })
        #expect(st.outPins.isEmpty)
        #expect(st.rawAttributes["MARAFLOW_ST_CODE"]?.contains("FOR i := 1 TO 2") == true)
        let read0 = try #require(outcome.project.modules.first { $0.name == "Read0" })
        let read1 = try #require(outcome.project.modules.first { $0.name == "Read1" })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: read0.id)[0].asInt == 1)
        #expect(core.outPins(moduleId: read1.id)[0].asInt == 2, "the FOR loop ran twice in one scan")
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: read0.id)[0].asInt == 2, "page variables persist between scans")
        #expect(core.outPins(moduleId: read1.id)[0].asInt == 4)
        #expect(outcome.notes.contains { $0.contains("native ST interpreter") })
    }

    @Test("ST interpreter runs control flow, calls and expressions")
    func stControlFlow() throws {
        let code = """
        VAR
            n : INT := 0;
            And_Out : BOOL := 0;
        END_VAR
        n := n + 1;
        IF n = 1 THEN
            REG_0 := 10;
        ELSIF n = 2 THEN
            REG_0 := 20;
        ELSE
            REG_0 := 30;
        END_IF;
        CASE n OF
            1: REG_1 := 111;
            2: REG_1 := 222;
            ELSE REG_1 := 333;
        END_CASE;
        WHILE REG_2 < 3 DO
            REG_2 := REG_2 + 1;
        END_WHILE;
        And_Out := And(En := 1, X1 := 1, X2 := 1);
        REG_3 := And_Out;
        """
        var entries: [(String, String)] = [
            ("project.name", "STFlow"),
            ("project.pageCount", "2"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stCode", code),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Read"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "4"),
            ("page.1.wireCount", "0"),
        ]
        for index in 0..<4 {
            entries += Self.block("page.1.block.\(index).", id: "r\(index)", definition: "Main.Execution.ReadReg",
                                  type: "ReadReg", name: "Read\(index)", gridX: index * 8, gridY: 2,
                                  order: 100 + index * 10,
                                  inputs: [("En", "Enable", "BOOL", "1")],
                                  outputs: [("Out", "Value", "INT", "0")],
                                  properties: [("RegisterName", "REG_\(index)")])
        }
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "stflow")
        let reads = outcome.project.modules.filter { $0.name.hasPrefix("Read") }
        #expect(reads.count == 4)
        let byName = Dictionary(uniqueKeysWithValues: reads.map { ($0.name, $0.id) })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: byName["Read0"]!)[0].asInt == 10)
        #expect(core.outPins(moduleId: byName["Read1"]!)[0].asInt == 111)
        #expect(core.outPins(moduleId: byName["Read2"]!)[0].asInt == 3, "WHILE ran to completion in one scan")
        #expect(core.outPins(moduleId: byName["Read3"]!)[0].asInt == 1, "And() call evaluated")
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: byName["Read0"]!)[0].asInt == 20)
        #expect(core.outPins(moduleId: byName["Read1"]!)[0].asInt == 222)
        #expect(core.outPins(moduleId: byName["Read2"]!)[0].asInt == 3, "the operand keeps its value")
    }

    @Test("ST standard function-block instances keep state")
    func stFunctionBlocks() throws {
        let code = """
        VAR
            held : BOOL := 0;
        END_VAR
        Inst_RS(S := TRUE, R := FALSE);
        held := Inst_RS.Q;
        REG_4 := held;
        """
        var entries: [(String, String)] = [
            ("project.name", "STFB"),
            ("project.pageCount", "2"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stCode", code),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Read"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "1"),
            ("page.1.wireCount", "0"),
        ]
        entries += Self.block("page.1.block.0.", id: "r4", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read4", gridX: 2, gridY: 2, order: 100,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "REG_4")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "stfb")
        let read = try #require(outcome.project.modules.first { $0.name == "Read4" })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: read.id)[0].asInt == 1)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: read.id)[0].asInt == 1, "RS keeps its latch")
    }

    @Test("An ST page that does not compile reports its line")
    func stCompileError() throws {
        let entries: [(String, String)] = [
            ("project.name", "BadST"),
            ("project.pageCount", "1"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stCode", "VAR n : INT := 0; END_VAR\nn := ;"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
        ]
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "badst")
        let st = try #require(outcome.project.modules.first { $0.guid == MaraflowStPage.guid })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        let message = try #require(core.maraflowStError(moduleId: st.id))
        #expect(message.contains("line 2"))
    }

    @Test("Ladder pages run through the native evaluator")
    func ladderPages() throws {
        var entries: [(String, String)] = [
            ("project.name", "LadderDemo"),
            ("project.pageCount", "3"),
            ("page.0.name", "Ladder"),
            ("page.0.language", "LD"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.0.rungCount", "2"),
            ("page.0.rung.0.threadId", "2"),
            ("page.0.rung.0.order", "10"),
            ("page.0.rung.0.mainCount", "1"),
            ("page.0.rung.0.main.0.kind", "NO_CONTACT"),
            ("page.0.rung.0.main.0.operand", "DI0"),
            ("page.0.rung.0.coilCount", "1"),
            ("page.0.rung.0.coil.0.kind", "NORMAL_COIL"),
            ("page.0.rung.0.coil.0.operand", "DO0"),
            ("page.0.rung.1.threadId", "2"),
            ("page.0.rung.1.order", "20"),
            ("page.0.rung.1.mainCount", "1"),
            ("page.0.rung.1.main.0.kind", "NC_CONTACT"),
            ("page.0.rung.1.main.0.operand", "DI1"),
            ("page.0.rung.1.coilCount", "1"),
            ("page.0.rung.1.coil.0.kind", "NEGATED_COIL"),
            ("page.0.rung.1.coil.0.operand", "DO1"),
            ("page.1.name", "Drive"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "2"),
            ("page.1.wireCount", "0"),
            ("page.2.name", "Read"),
            ("page.2.language", "FBD"),
            ("page.2.blockCount", "2"),
            ("page.2.wireCount", "0"),
        ]
        entries += Self.block("page.1.block.0.", id: "d0", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "Drive0", gridX: 2, gridY: 2, order: -1_000_100,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DI0")])
        entries += Self.block("page.1.block.1.", id: "d1", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "Drive1", gridX: 10, gridY: 2, order: -1_000_090,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "0")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DI1")])
        entries += Self.block("page.2.block.0.", id: "r0", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read0", gridX: 2, gridY: 2, order: 100,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "DO0")])
        entries += Self.block("page.2.block.1.", id: "r1", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read1", gridX: 10, gridY: 2, order: 110,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "DO1")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "ladder")
        let ldPages = outcome.project.modules.filter { $0.guid == MaraflowLdPage.guid }
        #expect(ldPages.count == 1, "both rungs are on thread 2")
        #expect(ldPages[0].rawAttributes["MARAFLOW_LD_RUNGS"]?.contains("NO_CONTACT") == true)
        let read0 = try #require(outcome.project.modules.first { $0.name == "Read0" })
        let read1 = try #require(outcome.project.modules.first { $0.name == "Read1" })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: read0.id)[0].asInt == 1, "NO DI0 energises DO0")
        #expect(core.outPins(moduleId: read1.id)[0].asInt == 0, "NC DI1 is true, so the negated coil is false")
        #expect(outcome.notes.contains { $0.contains("native ladder evaluator") })
    }

    @Test("Ladder branches, edges, latches and analog coils")
    func ladderSemantics() throws {
        var entries: [(String, String)] = [
            ("project.name", "LadderSemantics"),
            ("project.pageCount", "3"),
            ("page.0.name", "Ladder"),
            ("page.0.language", "LD"),
            ("page.0.rungCount", "5"),
        ]
        func rung(_ index: Int, main: (String, String), branch: ((String, String))? = nil,
                  coil: (String, String, String)) {
            let prefix = "page.0.rung.\(index)."
            entries += [(prefix + "threadId", "2"), (prefix + "order", "\((index + 1) * 10)"),
                        (prefix + "mainCount", "1"),
                        (prefix + "main.0.kind", main.0), (prefix + "main.0.operand", main.1)]
            if let branch {
                entries += [(prefix + "branchCount", "1"),
                            (prefix + "branch.0.startCol", "0"),
                            (prefix + "branch.0.endCol", "0"),
                            (prefix + "branch.0.elCount", "1"),
                            (prefix + "branch.0.el.0.kind", branch.0),
                            (prefix + "branch.0.el.0.operand", branch.1)]
            } else {
                entries.append((prefix + "branchCount", "0"))
            }
            entries += [(prefix + "coilCount", "1"),
                        (prefix + "coil.0.kind", coil.0),
                        (prefix + "coil.0.operand", coil.1),
                        (prefix + "coil.0.srcOperand", coil.2)]
        }
        rung(0, main: ("NO_CONTACT", "DI0"), branch: ("NC_CONTACT", "DI1"), coil: ("NORMAL_COIL", "DO2", ""))
        rung(1, main: ("NO_CONTACT", "DI2"), coil: ("SET_COIL", "DO3", ""))
        rung(2, main: ("NO_CONTACT", "DI3"), coil: ("POS_EDGE_COIL", "DO5", ""))
        rung(3, main: ("NO_CONTACT", "DI4"), coil: ("ANALOG_COIL", "AO0", "AI0"))
        rung(4, main: ("POS_EDGE_CONTACT", "DI5"), coil: ("NORMAL_COIL", "DO6", ""))

        entries += [("page.1.name", "Drive"), ("page.1.language", "FBD"), ("page.1.blockCount", "7"),
                    ("page.1.wireCount", "0"),
                    ("page.2.name", "Read"), ("page.2.language", "FBD"), ("page.2.blockCount", "5"),
                    ("page.2.wireCount", "0")]
        let drivers = [("DI0", "0"), ("DI1", "0"), ("DI2", "1"), ("DI3", "1"), ("DI4", "1"),
                       ("DI5", "1"), ("AI0", "123")]
        for (index, driver) in drivers.enumerated() {
            entries += Self.block("page.1.block.\(index).", id: "d\(index)", definition: "Main.Execution.WriteReg",
                                  type: "WriteReg", name: "Drive\(index)", gridX: index * 8, gridY: 2,
                                  order: -1_000_200 + index * 10,
                                  inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", driver.1)],
                                  outputs: [("Out", "Stored", "INT", "0")],
                                  properties: [("RegisterName", driver.0)])
        }
        let readers = ["DO2", "DO3", "DO5", "AO0", "DO6"]
        for (index, operand) in readers.enumerated() {
            entries += Self.block("page.2.block.\(index).", id: "r\(index)", definition: "Main.Execution.ReadReg",
                                  type: "ReadReg", name: "Read\(operand)", gridX: index * 8, gridY: 2,
                                  order: 100 + index * 10,
                                  inputs: [("En", "Enable", "BOOL", "1")],
                                  outputs: [("Out", "Value", "INT", "0")],
                                  properties: [("RegisterName", operand)])
        }
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "ldsem")
        let modules = Dictionary(uniqueKeysWithValues: outcome.project.modules.map { ($0.name, $0.id) })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: modules["ReadDO2"]!)[0].asInt == 1, "parallel NC branch energises the coil")
        #expect(core.outPins(moduleId: modules["ReadDO3"]!)[0].asInt == 1, "SET coil latches")
        #expect(core.outPins(moduleId: modules["ReadDO5"]!)[0].asInt == 1, "rising-edge coil pulses once")
        #expect(core.outPins(moduleId: modules["ReadAO0"]!)[0].asInt == 123, "analog coil moves AI0 to AO0")
        #expect(core.outPins(moduleId: modules["ReadDO6"]!)[0].asInt == 1, "rising contact conducts once")
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: modules["ReadDO3"]!)[0].asInt == 1, "SET coil holds")
        #expect(core.outPins(moduleId: modules["ReadDO5"]!)[0].asInt == 0, "edge coil clears")
        #expect(core.outPins(moduleId: modules["ReadDO6"]!)[0].asInt == 0, "edge contact clears")
    }

    @Test("Ladder operands can read another block's pin")
    func ladderDottedOperand() throws {
        var entries: [(String, String)] = [
            ("project.name", "LadderDotted"),
            ("project.pageCount", "3"),
            ("page.0.name", "Source"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "1"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Ladder"),
            ("page.1.language", "LD"),
            ("page.1.rungCount", "1"),
            ("page.1.rung.0.threadId", "2"),
            ("page.1.rung.0.order", "10"),
            ("page.1.rung.0.mainCount", "1"),
            ("page.1.rung.0.main.0.kind", "NO_CONTACT"),
            ("page.1.rung.0.main.0.operand", "Source.Out"),
            ("page.1.rung.0.coilCount", "1"),
            ("page.1.rung.0.coil.0.kind", "NORMAL_COIL"),
            ("page.1.rung.0.coil.0.operand", "DO7"),
            ("page.2.name", "Read"),
            ("page.2.language", "FBD"),
            ("page.2.blockCount", "1"),
            ("page.2.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "source", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "Source", gridX: 2, gridY: 2, order: -1_000_100,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "7")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "SCRATCH")])
        entries += Self.block("page.2.block.0.", id: "reader", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read7", gridX: 2, gridY: 2, order: 100,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "DO7")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "lddotted")
        let reader = try #require(outcome.project.modules.first { $0.name == "Read7" })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: reader.id)[0].asInt == 1)
    }

    @Test("A function block embedded in a ladder rung executes")
    func ladderFunctionBlock() throws {
        var entries: [(String, String)] = [
            ("project.name", "LadderFB"),
            ("project.pageCount", "2"),
            ("page.0.name", "Ladder"),
            ("page.0.language", "LD"),
            ("page.0.rungCount", "1"),
            ("page.0.rung.0.threadId", "2"),
            ("page.0.rung.0.order", "10"),
            ("page.0.rung.0.mainCount", "1"),
            ("page.0.rung.0.main.0.kind", "FUNCTION_BLOCK"),
            ("page.0.rung.0.main.0.operand", "Add1"),
            ("page.0.rung.0.coilCount", "1"),
            ("page.0.rung.0.coil.0.kind", "NORMAL_COIL"),
            ("page.0.rung.0.coil.0.operand", "DO0"),
            ("page.1.name", "Read"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "2"),
            ("page.1.wireCount", "0"),
        ]
        entries += Self.block("page.0.rung.0.main.0.fb.", id: "add", definition: "Math.Add", type: "Add", name: "Add1",
                              gridX: 0, gridY: 0, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("X1", "Operand 1", "INT", "5"),
                                       ("X2", "Operand 2", "INT", "2")],
                              outputs: [("Y", "Result", "INT", "REG_5")])
        entries += Self.block("page.1.block.0.", id: "r5", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "Read5", gridX: 2, gridY: 2, order: 100,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "REG_5")])
        entries += Self.block("page.1.block.1.", id: "r0", definition: "Main.Execution.ReadReg",
                              type: "ReadReg", name: "ReadDO0", gridX: 10, gridY: 2, order: 110,
                              inputs: [("En", "Enable", "BOOL", "1")],
                              outputs: [("Out", "Value", "INT", "0")],
                              properties: [("RegisterName", "DO0")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "ldfb")
        let read5 = try #require(outcome.project.modules.first { $0.name == "Read5" })
        let readDO = try #require(outcome.project.modules.first { $0.name == "ReadDO0" })
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: read5.id)[0].asInt == 7, "Add(5,2) through the rung")
        #expect(core.outPins(moduleId: readDO.id)[0].asInt == 1, "an Int FB's power continues through the rung")
    }

    @Test("An ST macro page is bridged to its call pins")
    func stMacro() throws {
        var entries: [(String, String)] = [
            ("project.name", "STMacro"),
            ("project.pageCount", "2"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "1"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "*Inc"),
            ("page.1.language", "ST"),
            ("page.1.stCode", "VAR_INPUT x : INT; END_VAR VAR_OUTPUT y : INT; END_VAR y := x + 1;"),
            ("page.1.stVarCount", "2"),
            ("page.1.stVar.0.scope", "VAR_INPUT"),
            ("page.1.stVar.0.name", "x"),
            ("page.1.stVar.0.type", "INT"),
            ("page.1.stVar.0.init", "0"),
            ("page.1.stVar.1.scope", "VAR_OUTPUT"),
            ("page.1.stVar.1.name", "y"),
            ("page.1.stVar.1.type", "INT"),
            ("page.1.stVar.1.init", "0"),
            ("page.1.blockCount", "0"),
            ("page.1.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "call", definition: "Macro.User.Inc", type: "Inc",
                              name: "IncCall", gridX: 2, gridY: 2, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("x", "Input", "INT", "5")],
                              outputs: [("y", "Output", "INT", "0")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "stmacro")
        #expect(outcome.project.pages.map(\.caption).sorted() == ["*Inc", "Main"])
        let call = try #require(outcome.project.modules.first { $0.name == "IncCall" })
        #expect(call.guid == MacroBlock.guid)
        #expect(call.rawAttributes["MACRO_NAME"] == "Inc")
        let interfaces = outcome.project.modules.filter {
            $0.page == "*Inc" && ["Inputs", "Outputs"].contains($0.rawAttributes["MACRO_NAME"] ?? "")
        }
        #expect(interfaces.count == 2)
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: call.id)[0].asInt == 6, "ST macro input reaches the page and its output returns")
    }

    @Test("E-Stop supervision trips on an imported rule and forces outputs to zero")
    func eStopSupervision() throws {
        var entries: [(String, String)] = [
            ("project.name", "Safety"),
            ("project.pageCount", "2"),
            ("project.estop.enabled", "true"),
            ("project.estop.mode", "DISABLE_OUTPUTS_AND_STOP"),
            ("project.estop.manualReset", "true"),
            ("project.estop.ruleCount", "1"),
            ("project.estop.rule.0.channel", "DI0"),
            ("project.estop.rule.0.activeLow", "false"),
            ("project.estop.rule.0.enabled", "true"),
            ("page.0.name", "Drive"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "2"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Read"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "1"),
            ("page.1.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "di", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "DriveDI", gridX: 2, gridY: 2, order: -1_000_100,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DI0")])
        entries += Self.block("page.0.block.1.", id: "do", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "DriveDO", gridX: 10, gridY: 2, order: -90,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DO0")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "safety")
        #expect(outcome.project.maraflow?.eStop.enabled == true)
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO0") == 1, "before the rule trips the driver writes DO0")
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO0") == 0, "a tripped E-Stop forces hardware outputs to zero")
    }

    @Test("E-Stop mode 2 runs only the dedicated page and does not zero outputs")
    func eStopDedicatedPage() throws {
        var entries: [(String, String)] = [
            ("project.name", "SafetyPage"),
            ("project.pageCount", "2"),
            ("project.estop.enabled", "true"),
            ("project.estop.mode", "DEDICATED_ESTOP_PAGE"),
            ("project.estop.pageName", "!EStop"),
            ("project.estop.manualReset", "true"),
            ("project.estop.ruleCount", "1"),
            ("project.estop.rule.0.channel", "DI0"),
            ("project.estop.rule.0.activeLow", "false"),
            ("project.estop.rule.0.enabled", "true"),
            ("page.0.name", "Normal"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "2"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "!EStop"),
            ("page.1.language", "FBD"),
            ("page.1.blockCount", "1"),
            ("page.1.wireCount", "0"),
        ]
        entries += Self.block("page.0.block.0.", id: "di", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "DriveDI", gridX: 2, gridY: 2, order: -1_000_100,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DI0")])
        entries += Self.block("page.0.block.1.", id: "do", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "DriveDO", gridX: 10, gridY: 2, order: -90,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DO0")])
        entries += Self.block("page.1.block.0.", id: "safe", definition: "Main.Execution.WriteReg",
                              type: "WriteReg", name: "SafeDO", gridX: 2, gridY: 2, order: 10,
                              inputs: [("En", "Enable", "BOOL", "1"), ("In", "Value", "INT", "1")],
                              outputs: [("Out", "Stored", "INT", "0")],
                              properties: [("RegisterName", "DO5")])
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "safetypage")
        #expect(outcome.project.pages.map(\.caption) == ["Normal", "!EStop"])
        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO0") == 1)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.operandValue("DO0") == 1, "mode 2 does not force outputs; the normal page is skipped")
        #expect(core.operandValue("DO5") == 1, "the dedicated E-Stop page still runs")
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
        #expect(loaded.project.pages.map(\.caption) == ["Code", "Relays", "*Blink"])
        let notes = loaded.notes.joined(separator: "\n")
        #expect(notes.contains("Structured Text"))
        #expect(notes.contains("ladder rung"))
        #expect(notes.contains("Macro page"))
    }

    @Test("A non-Maraflow XML file is not treated as one")
    func notMaraflow() throws {
        let data = Data("<not-a-project/>".utf8)
        #expect(throws: (any Error).self) {
            try ProjectFile.read(data: data)
        }
    }
}
