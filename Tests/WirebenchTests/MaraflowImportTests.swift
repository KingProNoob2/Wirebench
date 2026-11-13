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
        #expect(output.guid == BlockTypeCatalog.info(forBlockName: "8xDO")?.guid)
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
            ("page.0.graphic.0.text", "Pump"),
        ]
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "extras")
        let extras = try #require(outcome.project.maraflow)
        #expect(extras.formatVersion == "1.0.0")
        #expect(extras.properties["project.tag.0.name"] == "Speed")
        #expect(extras.properties["project.estop.enabled"] == "true")
        #expect(extras.properties["page.0.graphic.0.text"] == "Pump")
        let decoded = try WirebenchDocument.decode(WirebenchDocument.encode(outcome.project))
        #expect(decoded.maraflow == extras)
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
        #expect(timer.guid == BlockTypeCatalog.info(forBlockName: "Timer")?.guid)
        #expect(pulse.guid == BlockTypeCatalog.info(forBlockName: "PulseGen")?.guid)
        #expect(single.guid == BlockTypeCatalog.info(forBlockName: "SinglePulse")?.guid)
        #expect(timer.paramPins.first?.value.asInt == 2)
        #expect(pulse.paramPins.map(\.value.asInt) == [1, 1])

        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: pulse.id)[1].asBool, "PulseGen is high in its first on-cycle")
        #expect(core.outPins(moduleId: single.id)[1].asBool, "SinglePulse fires on the rising trigger")
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
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
        #expect(decode.guid == BlockTypeCatalog.info(forBlockName: "DecodeDate")?.guid)
        #expect(decode.outPins[2].name == "Yr", "Year maps to the third output")
        #expect(encode.guid == BlockTypeCatalog.info(forBlockName: "EncodeDate")?.guid)
        #expect(encode.inPins[3].name == "Yr", "Year maps to the fourth input")
        #expect(encode.inPins[3].value.asInt == 2026)
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

    @Test("ST pages convert their declarations and generated block calls")
    func stPage() throws {
        let code = """
        VAR
            And_Out : BOOL;
            Sum_Out : INT;
        END_VAR

        // Block: Bool.And
        And_Out := And(
            X1 := 1,
            X2 := 1
        );

        // Block: Math.Add
        Sum_Out := Add(
            X1 := 5,
            X2 := 2
        );
        """
        let entries: [(String, String)] = [
            ("project.name", "STDemo"),
            ("project.pageCount", "1"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stCode", code),
            ("page.0.stVarCount", "0"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
        ]
        let outcome = try MaraflowImporter.importProject(data: Self.propertiesXML(entries), filename: "stdemo")
        #expect(outcome.project.pages.map(\.caption) == ["Logic"])
        let andOut = try #require(outcome.project.modules.first { $0.name == "And_Out" })
        let sumOut = try #require(outcome.project.modules.first { $0.name == "Sum_Out" })
        #expect(andOut.guid == BlockTypeCatalog.info(forBlockName: "BoolVar")?.guid)
        #expect(sumOut.guid == BlockTypeCatalog.info(forBlockName: "IntVar")?.guid)
        #expect(outcome.project.modules.contains { $0.guid == BlockTypeCatalog.info(forBlockName: "And")?.guid })
        #expect(outcome.project.modules.contains { $0.guid == BlockTypeCatalog.info(forBlockName: "IAdd")?.guid })

        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.outPins(moduleId: andOut.id)[0].asBool)
        #expect(core.outPins(moduleId: sumOut.id)[0].asInt == 7)
        #expect(outcome.notes.contains { $0.contains("Structured Text") && $0.contains("converted") })
    }

    static func ladderProject() -> Data {
        var entries: [(String, String)] = [
            ("project.name", "LadderDemo"),
            ("project.pageCount", "1"),
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
        ]
        return Self.propertiesXML(entries)
    }

    @Test("Simple ladder rungs become DI, logic and DO blocks")
    func ladderPages() throws {
        let outcome = try MaraflowImporter.importProject(data: Self.ladderProject(), filename: "ladder")
        let di = try #require(outcome.project.modules.first { $0.guid == BlockTypeCatalog.info(forBlockName: "8xDI")?.guid })
        let output = try #require(outcome.project.modules.first { $0.guid == BlockTypeCatalog.info(forBlockName: "8xDO")?.guid })
        #expect(outcome.project.modules.contains { $0.guid == BlockTypeCatalog.info(forBlockName: "Not")?.guid })
        #expect(outcome.notes.contains { $0.contains("ladder block") })
        #expect(outcome.project.connection(inModuleId: output.id, inPinId: 1)?.outModuleId == di.id)

        let core = CxxSimulationCore(project: outcome.project, profileScheduling: false)
        core.setOut(moduleId: di.id, pin: 0, value: .bool(true))
        core.setOut(moduleId: di.id, pin: 1, value: .bool(false))
        core.step(deltaMs: 10, now: Date(timeIntervalSince1970: 0))
        #expect(core.inPins(moduleId: output.id)[1].asBool, "NO DI0 energises DO0")
        #expect(!core.inPins(moduleId: output.id)[2].asBool, "NC DI1 is true, then the negated coil makes DO1 false")
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
        #expect(notes.contains("ladder block"))
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
