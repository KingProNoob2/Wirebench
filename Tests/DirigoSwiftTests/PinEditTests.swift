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

    /// An index from outside must be **rejected, not subscripted**.
    ///
    /// Every pin mutator here guarded only the *upper* bound — `pinIndex < count` — so a negative index
    /// passed the check and subscripted the array out of bounds, which is a trap rather than a wrong
    /// value. The same shape existed in `EightDIBlock.togglePin`, which is why that one is covered
    /// through the entry point below as well as directly.
    ///
    /// This is the reachable half of the "unreproduced segfault" in `performance.md` §6: a negative pin
    /// index is a way to crash the app from the inspector, and the crash was recorded without a cause.
    /// If the guard is removed, this test does not fail an assertion — it **kills the test process**,
    /// which is exactly the failure mode being guarded against.
    @Test("An out-of-range pin index is rejected, not subscripted")
    func rejectsOutOfRangePinIndices() throws {
        let model = try Self.load(Self.switchProject())
        let node = model.getNode(id: 1)
        let inPinsBefore = node?.block.inPins.map(\.description) ?? []
        let outPinsBefore = node?.block.outPins.map(\.description) ?? []

        // Both ends of the range, through every mutator that takes an index.
        for index in [-1, -100, 99, Int.min, Int.max] {
            model.setModuleInput(moduleId: 1, pinIndex: index, value: .int32(1234))
            model.setModuleOutput(moduleId: 1, pinIndex: index, value: .bool(true))
            model.toggleModuleInput(moduleId: 1, pinIndex: index)
            model.setModuleInputPressed(moduleId: 1, pinIndex: index, isPressed: true)
            model.setModuleInputPressed(moduleId: 1, pinIndex: index, isPressed: false)
        }

        // Nothing was written *by the out-of-range index*. The input and the document must be untouched,
        // and no output outside the range may exist.
        #expect(model.getNode(id: 1)?.block.inPins.map(\.description) == inPinsBefore,
                "an out-of-range index changed an input pin")
        #expect(model.project?.modules.first?.inPins.map { $0.value.description } == inPinsBefore,
                "an out-of-range index reached the document")

        // `outPins` is *not* asserted unchanged: this fixture is an `ISwitch`, whose output is a function
        // of its inputs, so a legitimate in-range write propagating to the output is correct. What must
        // hold is that the writes went nowhere near an index outside the range.
        #expect(model.getNode(id: 1)?.block.outPins.count == outPinsBefore.count,
                "an out-of-range index changed the shape of the output pins")

        // The guard must reject, not disable: the neighbouring `clickToggles` test covers the in-range
        // behaviour, and this checks it still holds after the hostile indices above.
        #expect(model.getNode(id: 1)?.block.inPins[3].description == "8",
                "the in-range pin this fixture asserts on was disturbed")
    }

    /// `EightDIBlock.togglePin` took the index directly, so it needs its own case: it is reached through
    /// `toggleModuleInput`, not through the generic in/out pin paths.
    @Test("An out-of-range index is rejected by the 8xDI channel toggle too")
    func eightDIToggleRejectsOutOfRange() throws {
        var project = PCCProject(name: "8xdi")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: EightDIBlock.guid, name: "8xDI1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [], outPins: (0..<8).map { Pin(id: $0, value: .bool(false)) }),
        ]
        let model = try Self.load(project)
        let before = model.getNode(id: 1)?.block.outPins.map(\.description) ?? []
        #expect(!before.isEmpty, "the fixture must expose output pins to toggle")

        for index in [-1, -8, 8, 99, Int.min] {
            model.toggleModuleInput(moduleId: 1, pinIndex: index)
        }
        #expect(model.getNode(id: 1)?.block.outPins.map(\.description) == before,
                "an out-of-range index toggled a channel")

        // And the in-range case still works, so the guard did not disable the feature.
        model.toggleModuleInput(moduleId: 1, pinIndex: 0)
        #expect(model.getNode(id: 1)?.block.outPins[0].description == "1",
                "an in-range toggle must still work")
    }

    @Test("A click clears a set pin, and the next click brings its value back")
    func clickToggles() throws {
        let model = try Self.load(Self.switchProject())
        func pin(_ index: Int) -> PinValue? { model.getNode(id: 1)?.block.inPins[index] }

        #expect(pin(3)?.description == "8")
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)
        #expect(pin(3)?.description == "0", "a set pin clears")
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)
        #expect(pin(3) == .int32(8), "the value it had comes back, as an integer")
        // A pin that was never set has nothing to remember, so it sets to 1.
        model.toggleModuleInput(moduleId: 1, pinIndex: 1)
        #expect(pin(1) == .int32(1))
    }

    @Test("A value typed while the pin is cleared is what the next clear and set come back to")
    func typedValueReplacesRemembered() throws {
        let model = try Self.load(Self.switchProject())
        func pin(_ index: Int) -> PinValue? { model.getNode(id: 1)?.block.inPins[index] }

        model.toggleModuleInput(moduleId: 1, pinIndex: 3)          // 8 -> 0
        model.setModuleInput(moduleId: 1, pinIndex: 3, value: .int32(0))
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)          // typed over: nothing remembered
        #expect(pin(3) == .int32(1))
        model.setModuleInput(moduleId: 1, pinIndex: 3, value: .int32(5))
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)          // 5 -> 0
        model.toggleModuleInput(moduleId: 1, pinIndex: 3)          // -> 5
        #expect(pin(3) == .int32(5))
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
        let school = TestCorpus.directories[0]
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
        let school = TestCorpus.directories[0]
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
