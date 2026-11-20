import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchModel
import WirebenchMaraVM
@testable import WirebenchHardware

@Suite("Duino-S MFLW compiler")
struct DuinoCompilerTests {
    private func project(_ modules: [PCCModule], connections: [Connection] = []) -> PCCProject {
        var project = PCCProject(name: "duino-test")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = modules
        project.inConnections = connections
        return project
    }

    private func maraflowBlock(id: Int, _ definitionID: String, thread: Int = 1, order: Int = 10,
                               inputs: [PinValue], outputs: [PinValue]) -> PCCModule {
        let definition = MaraflowCatalog.byId[definitionID]!
        return PCCModule(id: id, guid: definition.guid, name: "\(definition.typeName)\(id)",
                         x: 0, y: 0, order: order, threadId: thread, page: "Main",
                         inPins: inputs.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         paramPins: [],
                         outPins: outputs.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                         rawAttributes: AttributeBag([("MARAFLOW_DEF", definitionID)]))
    }

    private func wire(_ from: Int, _ out: Int, _ to: Int, _ input: Int) -> Connection {
        Connection(inModuleId: to, inPinId: input, outModuleId: from, outPinId: out)
    }

    @Test("A BOOL And compiles to a loadable MFLW image and runs in the firmware VM")
    func andRuns() throws {
        let and = maraflowBlock(id: 1, "Bool.And", inputs: [.bool(true), .bool(true), .bool(true)], outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([and]))
        #expect(result.image.count >= 72)
        #expect(Array(result.image[0..<2]) == [0x4D, 0x46]) // "MF"
        #expect(Array(result.image[2..<4]) == [0x4C, 0x57]) // "LW"
        let vm = MaraVM()
        try vm.load(result.image)
        #expect(vm.hasValidImage)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        let slot = try #require(result.slots["And1.Y"])
        #expect(vm.readBool(slot))
    }

    @Test("A wire carries the source value to a comparator")
    func wireRuns() throws {
        let source = maraflowBlock(id: 1, "Visual.Vars.IntVar", order: 10,
                                   inputs: [], outputs: [.int32(42)])
        let comparator = maraflowBlock(id: 2, "Main.Comparators.EQ", order: 20,
                                       inputs: [.bool(true), .int32(0), .int32(42)],
                                       outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([source, comparator],
                                                                connections: [wire(1, 0, 2, 1)]))
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        let resultSlot = try #require(result.slots["EQ2.Y"])
        #expect(vm.readBool(resultSlot))
    }

    @Test("A wire from a later block is readable by an earlier one")
    func feedbackWire() throws {
        let source = maraflowBlock(id: 2, "Visual.Vars.IntVar", order: 20,
                                   inputs: [], outputs: [.int32(7)])
        let comparator = maraflowBlock(id: 1, "Main.Comparators.EQ", order: 10,
                                       inputs: [.bool(true), .int32(0), .int32(7)],
                                       outputs: [.bool(false)])
        let result = try DuinoCompiler.compile(project: project([comparator, source],
                                                                connections: [wire(2, 0, 1, 1)]))
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.readBool(try #require(result.slots["EQ1.Y"])))
    }

    @Test("A timer counts elapsed time in the firmware VM")
    func timerRuns() throws {
        let timer = maraflowBlock(id: 1, "Main.Timers.Timer",
                                  inputs: [.bool(true), .bool(true), .int32(20)],
                                  outputs: [.bool(false), .int32(0)])
        let result = try DuinoCompiler.compile(project: project([timer]))
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        let q = try #require(result.slots["Timer1.Q"])
        let et = try #require(result.slots["Timer1.ET"])
        for _ in 0..<4 { try vm.step(thread: 1, dtMicroseconds: 5_000) }
        #expect(vm.readInt(et) == 20)
        #expect(vm.readBool(q))
    }

    @Test("The nested macro project expands and compiles")
    func nestedMacros() throws {
        let project = NestedMacroTests.project()
        let result = try DuinoCompiler.compile(project: project)
        #expect(result.image.count > 72)
        #expect(!result.slots.isEmpty)
        let vm = MaraVM()
        try vm.load(result.image)
        try vm.reset()
        try vm.setRunning()
        try vm.step(thread: 1)
        #expect(vm.lastFaultCode == 0)
    }

    @Test("The image header names the Duino-S model and covers the payload with CRC32")
    func header() throws {
        let block = maraflowBlock(id: 1, "Bool.And", inputs: [.bool(true), .bool(true), .bool(true)], outputs: [.bool(false)])
        let image = try DuinoCompiler.compile(project: project([block])).image
        #expect(UInt16(image[6]) | (UInt16(image[7]) << 8) == 0x0407)
        #expect(UInt32(image[8]) | (UInt32(image[9]) << 8) | (UInt32(image[10]) << 16) | (UInt32(image[11]) << 24)
                == UInt32(image.count))
        let stored = UInt32(image[12]) | (UInt32(image[13]) << 8) | (UInt32(image[14]) << 16) | (UInt32(image[15]) << 24)
        #expect(stored == MaraProtFrame.crc32(image[72...]))
    }
}
