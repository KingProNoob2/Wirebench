import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// `8xDO`'s card: its pins are `En` plus the channels its `HIDDEN_PIN_MASK` leaves visible, named `DO<channel>`.
@Suite("8xDO configuration")
struct DigitalOutputConfigTests {
    @Test("A Delphi hex mask reads as hex, with or without the sign")
    func maskParsing() {
        #expect(PinMask.parse("$0473") == 0x473)
        #expect(PinMask.parse("0x0773") == 0x773)
        #expect(PinMask.parse("$00FF") == 0xFF)
        #expect(PinMask.parse("12") == 12)
        #expect(PinMask.parse("junk") == 0)
    }

    /// `PIN_COUNT=14 HIDDEN_PIN_MASK=$0773` — `had.pcc`'s 8xDO1: channels 2, 3, 7, 11, 12, 13 are shown.
    private func module(pins: Int = 7) -> PCCModule {
        PCCModule(id: 10, guid: EightDOBlock.guid, name: "8xDO1", x: 0, y: 0, order: 40,
                  threadId: 2, page: "main",
                  inPins: (0..<pins).map { Pin(id: $0, value: $0 == 0 ? .bool(true) : .bool(false)) },
                  outPins: [],
                  rawAttributes: ["PIN_COUNT": "14", "HIDDEN_PIN_MASK": "$0773"])
    }

    @Test("The card is named En, DO2, DO3, DO7, DO11, DO12, DO13")
    func pinNames() {
        let m = module()
        let labels = (0..<m.inPins.count).map { ModulePinCatalog.inputPinLabel(for: m, index: $0) }
        #expect(labels == ["En", "DO2", "DO3", "DO7", "DO11", "DO12", "DO13"])
    }

    @Test("Changing the visible channels moves the pins, their values and their wires with them")
    @MainActor
    func reconfigure() throws {
        var project = PCCProject(name: "do")
        project.pages = [ProjectPage(caption: "main")]
        var m = module()
        m.inPins[1].value = .bool(true)                      // DO2 on
        m.inPins[3].value = .bool(true)                      // DO7 on
        project.modules = [
            m,
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "BoolVar1", x: 0, y: 0, order: 10,
                      threadId: 2, page: "main", inPins: [], outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        project.inConnections = [
            Connection(inModuleId: 10, inPinId: 3, outModuleId: 1, outPinId: 0, isParam: false),   // → DO7
            Connection(inModuleId: 10, inPinId: 1, outModuleId: 1, outPinId: 0, isParam: false),   // → DO2
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("do-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)

        // Hide DO2 and show DO4: DO7 keeps its pin (now index 2); DO2's wire goes; DO4 is new.
        model.update8xDOConfig(id: 10, pinCount: 14, hiddenMaskHex: "$0F6F")
        let after = try #require(model.module(id: 10))
        let labels = (0..<after.inPins.count).map { ModulePinCatalog.inputPinLabel(for: after, index: $0) }
        #expect(labels == ["En", "DO4", "DO7", "DO12", "DO13"], "got \(labels)")
        #expect(after.rawAttributes["HIDDEN_PIN_MASK"] == "$0F6F")
        let channels = labels.dropFirst().compactMap { Int($0.dropFirst(2)) }
        #expect(channels == (0..<14).filter { 0x0F6F & (1 << $0) == 0 })
        let do7 = try #require(channels.firstIndex(of: 7)).advanced(by: 1)
        #expect(after.inPins[do7].value.asBool, "DO7's value comes along")
        let wires = model.project?.inConnections.filter { $0.inModuleId == 10 } ?? []
        #expect(wires.count == 1 && wires[0].inPinId == do7, "DO7's wire follows its pin; DO2's is dropped")
    }
}

/// An `IntVar` holds a value that nothing but a `Set` block or a person can change.
@Suite("IntVar by hand")
struct IntVarEditTests {
    @MainActor
    private func model() throws -> AppModel {
        var project = PCCProject(name: "intvar")
        project.pages = [ProjectPage(caption: "main")]
        project.appOptions.cycleDelay = 10
        project.modules = [
            PCCModule(id: 1, guid: IntVarBlock.guid, name: "IntVar1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main", inPins: [], outPins: [Pin(id: 0, value: .int32(0))]),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("intvar-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return model
    }

    @Test("A value typed over an IntVar sticks through further steps, on whichever engine runs it")
    @MainActor
    func valueSticks() throws {
        let model = try model()
        model.setVariableValue(moduleId: 1, value: 42)
        #expect(model.getNode(id: 1)?.block.outPins.first?.asInt == 42)
        for _ in 0..<5 { model.step() }
        #expect(model.getNode(id: 1)?.block.outPins.first?.asInt == 42,
                "the variable kept what was written")
        model.setVariableValue(moduleId: 1, value: -7)
        model.step()
        #expect(model.getNode(id: 1)?.block.outPins.first?.asInt == -7)
    }

    #if canImport(SwiftUI)
    @Test("The inspector offers an editable value for an IntVar's output, and not for other blocks")
    @MainActor
    func inspectorBinding() throws {
        let model = try model()
        let module = try #require(model.module(id: 1))
        let binding = try #require(InspectorView.editableVariable(model: model, module: module, value: .int32(0)))
        binding.wrappedValue = 9
        #expect(binding.wrappedValue == 9)
        #expect(model.getNode(id: 1)?.block.outPins.first?.asInt == 9)
    }
    #endif

    // MARK: - The slider on the card

    /// How Dirigo itself writes an IntVar with a slider: `SimulMode="3" HighValue="255"` (six such blocks in three real projects).
    @MainActor
    private func dirigoSliderModel() throws -> AppModel {
        var project = PCCProject(name: "intvar")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: IntVarBlock.guid, name: "IntVar1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main", simulMode: 3, inPins: [], outPins: [Pin(id: 0, value: .int32(0))],
                      rawAttributes: ["SimulMode": "3", "HighValue": "255"]),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("intvar-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return model
    }

    @Test("The slider's range is the HighValue Dirigo wrote, and a change to it is written back there")
    @MainActor
    func sliderRangeFromDirigo() throws {
        let model = try dirigoSliderModel()
        #expect(BlockRole.sliderMax(of: try #require(model.module(id: 1))) == 255, "loaded from the file, not 100")

        model.setSliderMax(id: 1, max: 40)
        let changed = try #require(model.module(id: 1))
        #expect(BlockRole.sliderMax(of: changed) == 40)
        #expect(changed.rawAttributes["HighValue"] == "40", "where Dirigo reads it")
        #expect(changed.rawAttributes["X_SliderMax"] == nil, "no second copy of the range")

        // Saved and opened again, it is still 40.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("intvar-saved-\(UUID()).pcc")
        try model.saveProject(to: out)
        let reopened = AppModel()
        reopened.loadProject(url: out)
        #expect(BlockRole.sliderMax(of: try #require(reopened.module(id: 1))) == 40)
    }

    @Test("An IntVar's slider reaches 100 unless told otherwise, and what it is told is stored as an extra")
    @MainActor
    func sliderMaximum() throws {
        let model = try model()
        let module = { try #require(model.module(id: 1)) }
        #expect(BlockRole.sliderMax(of: try module()) == 100)

        model.setSliderMax(id: 1, max: 500)
        #expect(BlockRole.sliderMax(of: try module()) == 500)
        #expect(try module().rawAttributes["X_SliderMax"] == "500")
        #expect(model.isDocumentEdited)

        // Back to the default: nothing is left in the file for the export to report.
        model.setSliderMax(id: 1, max: 100)
        #expect(try module().rawAttributes["X_SliderMax"] == nil)
        #expect(BlockRole.sliderMax(of: try module()) == 100)

        // A slider cannot be shorter than one step.
        model.setSliderMax(id: 1, max: 0)
        #expect(BlockRole.sliderMax(of: try module()) == 1)
        model.setSliderMax(id: 1, max: -50)
        #expect(BlockRole.sliderMax(of: try module()) == 1)
    }

    @Test("The slider's maximum survives a save and a reload")
    @MainActor
    func sliderMaximumRoundTrips() throws {
        let model = try model()
        model.setSliderMax(id: 1, max: 255)
        let xml = PCCSerializer().serialize(project: try #require(model.project))
        let reloaded = try PCCParser().parse(xmlString: xml)
        #expect(BlockRole.sliderMax(of: try #require(reloaded.modules.first)) == 255)
    }

    @Test("Only variables have a slider: a BoolVar's maximum is not stored")
    @MainActor
    func sliderIsForVariables() throws {
        var project = PCCProject(name: "mixed")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "BoolVar1", x: 0, y: 0, order: 10, threadId: 1,
                      page: "main", inPins: [], outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        let model = AppModel()
        model.project = project
        model.setSliderMax(id: 1, max: 500)
        #expect(model.module(id: 1)?.rawAttributes["X_SliderMax"] == nil)
    }

    @Test("IntVar and LongVar are driven by a slider, BoolVar by a button, and the card has room for either")
    func classification() {
        func module(_ guid: UUID) -> PCCModule {
            PCCModule(id: 1, guid: guid, name: "M", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                      inPins: [], outPins: [Pin(id: 0, value: .int32(0))])
        }
        let longVar = BlockTypeCatalog.all.first { $0.blockName == "LongVar" }!.guid
        #expect(BlockInteraction.classify(module(IntVarBlock.guid)) == .slider)
        #expect(BlockInteraction.classify(module(longVar)) == .slider)
        #expect(BlockInteraction.classify(module(BoolVarBlock.guid)) == .control)
        let plain = BlockTypeCatalog.all.first { $0.blockName == "And" }!.guid
        #expect(BlockInteraction.classify(module(plain)) == .none)
        // Room for the slider, as for BoolVar's button.
        #expect(CardGeometry.cardHeight(for: module(IntVarBlock.guid))
                >= CardGeometry.cardHeight(for: module(plain)) + CardGeometry.controlHeight)
    }

    @Test("Dragging the slider writes the variable, and it stays put")
    @MainActor
    func sliderWritesTheVariable() throws {
        let model = try model()
        // What the card's slider calls for each step of a drag.
        for value in [3, 40, 100] {
            model.setVariableValue(moduleId: 1, value: value)
            #expect(model.getNode(id: 1)?.block.outPins.first?.asInt == value)
        }
        model.step()
        #expect(model.getNode(id: 1)?.block.outPins.first?.asInt == 100)
    }

    @Test("Exporting for Dirigo removes the slider's maximum, says so, and leaves untouched blocks alone")
    func exportDropsTheMaximum() {
        var project = PCCProject(name: "export")
        project.pages = [ProjectPage(caption: "main")]
        var changed = PCCModule(id: 1, guid: IntVarBlock.guid, name: "Level", x: 0, y: 0, order: 10, threadId: 1,
                                page: "main", inPins: [], outPins: [Pin(id: 0, value: .int32(0))])
        changed.setExtraProperty("SliderMax", .int(500))
        let untouched = PCCModule(id: 2, guid: IntVarBlock.guid, name: "Other", x: 0, y: 0, order: 20, threadId: 1,
                                  page: "main", inPins: [], outPins: [Pin(id: 0, value: .int32(0))])
        project.modules = [changed, untouched]

        let result = ExtraPropertyTranslator.translate(project, declarations: ExtraPropertyCatalog.byGuid)
        #expect(result.project.modules.allSatisfy { $0.rawAttributes["X_SliderMax"] == nil })
        #expect(result.notes == ["Level: removed SliderMax — no Dirigo counterpart"])
        // The original sees the project it always did.
        #expect(!PCCSerializer().serialize(project: result.project).contains("X_"))
    }
}

