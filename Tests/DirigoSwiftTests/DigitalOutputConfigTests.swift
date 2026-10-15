import Testing
import Foundation
import DirigoCore
import DirigoLibrary
@testable import DirigoApp

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
