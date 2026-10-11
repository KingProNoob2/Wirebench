import Testing
import Foundation
import DirigoCore
import DirigoLibrary
import DirigoEngine
@testable import DirigoApp

/// Driving an input pin by hand, from the inspector.
///
/// A `Switch`'s `X3 = 8` is a value in the sheet, not a wire, so it has to be writable: clicking clears
/// it, clicking again sets it, and the number itself can be typed over. The value's *kind* is kept —
/// turning `8` into a Boolean would lose the fact that the pin is an integer.
@Suite("Writing pins by hand")
@MainActor
struct PinEditTests {
    static func switchProject() -> PCCProject {
        var project = PCCProject(name: "iswitch")
        project.pages = [ProjectPage(caption: "main")]
        project.appOptions.cycleDelay = 10
        project.modules = [
            PCCModule(id: 1, guid: ISwitchBlock.guid, name: "ISwitch1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(0)),
                               Pin(id: 2, value: .int32(1)), Pin(id: 3, value: .int32(8))],
                      paramPins: [],
                      outPins: [Pin(id: 0, value: .int32(0))]),
        ]
        return project
    }

    static func load(_ project: PCCProject) throws -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinedit-\(UUID().uuidString).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return model
    }

    @Test("A click clears a set pin, and the next click sets it")
    func clickToggles() throws {
        let model = try Self.load(Self.switchProject())
        func pin(_ index: Int) -> PinValue? { model.getNode(id: 1)?.block.inPins[index] }

        #expect(pin(3)?.description == "8")
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)
        #expect(pin(3)?.description == "0", "a set pin clears")
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)
        #expect(pin(3)?.description == "1", "and a clear pin sets")
        // The kind survived: an integer pin stayed an integer rather than becoming a Boolean.
        #expect(pin(3) == .int32(1))
    }

    @Test("A typed value is written, kept as its own kind, and saved to the document")
    func typedValueSticks() throws {
        let model = try Self.load(Self.switchProject())
        model.setModuleInput(moduleId: 1, pinIndex: 3, value: .int32(128))

        #expect(model.getNode(id: 1)?.block.inPins[3].description == "128")
        let saved = model.project?.modules.first { $0.id == 1 }?.inPins[3].value
        #expect(saved?.description == "128", "the sheet's own value must change, or saving would lose it")
        #expect(model.isDocumentEdited)
        // Asked as `asBool`, not by case: a round trip through the sheet stores `En` as the integer its
        // pin type declares, so the case is not what the test is about.
        #expect(model.project?.modules.first { $0.id == 1 }?.inPins[0].value.asBool == true,
                "the other pins are untouched")
    }

    @Test("On the C++ core, a hand edit takes effect without waiting for a tick")
    func editReachesTheCore() throws {
        let school = URL(fileURLWithPath: "/Users/erik/Nextcloud/School")
            .appendingPathComponent("Informační a Řídící Systémy").appendingPathComponent("Dirigo")
        let url = school.appendingPathComponent("had.pcc")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let model = AppModel()
        model.loadProject(url: url)
        #expect(model.isUsingCxxCore, "had.pcc is fully ported")
        model.step()   // a freshly loaded block still holds its own initial output, which is zero

        // `X0` is free — the file wires only the switch's selector — and with `Sw` at 0 it is the value
        // the switch passes through. Setting it by hand must reach the core immediately.
        #expect(model.getNode(id: 5)?.block.inPins[2].description == "1")
        #expect(model.getNode(id: 5)?.block.outPins[0].description == "1")
        model.setModuleInput(moduleId: 5, pinIndex: 2, value: .int32(128))
        #expect(model.getNode(id: 5)?.block.outPins[0].description == "128",
                "the core must have taken the new X0 and passed it through")
    }

    @Test("A wire still wins over a value typed into a wired pin")
    func wireBeatsHandEdit() throws {
        let school = URL(fileURLWithPath: "/Users/erik/Nextcloud/School")
            .appendingPathComponent("Informační a Řídící Systémy").appendingPathComponent("Dirigo")
        let url = school.appendingPathComponent("had.pcc")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let model = AppModel()
        model.loadProject(url: url)
        model.step()

        // `had.pcc` wires `ISwitch1.Sw` from `Counter1.Y`. Writing a value there is allowed — a person can
        // edit any pin — but the next step puts the wire's value back, which is what a wired input means.
        model.setModuleInput(moduleId: 5, pinIndex: 1, value: .int32(1))
        model.step()
        #expect(model.getNode(id: 5)?.block.inPins[1].description
                == model.getNode(id: 3)?.block.outPins[0].description,
                "the wire from Counter1.Y should own the pin again")
    }
}
