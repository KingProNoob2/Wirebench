import Testing
import Foundation
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel
@testable import WirebenchCore
@testable import WirebenchLibrary

/// Choosing a `SystemCmd` variant in the editor, and what the block then shows.
@Suite("SystemCmd variants in the editor")
struct SystemCmdEditingTests {
    @MainActor
    func modelWithSystemCmd() throws -> (AppModel, Int) {
        let model = AppModel()
        model.createNewProject()
        let id = try #require(model.addBlock(guid: SystemCmdBlock.guid))
        return (model, id)
    }

    @Test("A definition written from a catalogue entry reads back as the same command")
    @MainActor func definitionRoundTrip() throws {
        let (model, _) = try modelWithSystemCmd()
        let catalogue = model.systemCommandCatalogue
        #expect(!catalogue.isEmpty, "the default profile lists commands")
        for info in catalogue {
            let back = try #require(ProfilesParser.systemCommand(fromDefinition: info.definitionString), "\(info.mnemonic)")
            #expect(back.command == info.command && back.text == info.text)
            #expect(back.input1 == info.input1 && back.input2 == info.input2 && back.output == info.output)
        }
    }

    @Test("Choosing a command names the pins after it and puts its command word on Cmd")
    @MainActor func chooseCommand() throws {
        let (model, id) = try modelWithSystemCmd()
        let pwm = try #require(model.systemCommandCatalogue.first { !$0.input1.isHidden && !$0.output.isHidden })
        model.setSystemCommand(moduleId: id, to: pwm)
        let module = try #require(model.module(id: id))
        #expect(module.inPins[1].value.asInt == Int(pwm.command))
        let schema = ModulePinCatalog.pinNames(for: module)
        #expect(schema.paramPins.map(\.shortcut) == [pwm.input1.isHidden ? "I1" : pwm.input1.name, pwm.input2.isHidden ? "I2" : pwm.input2.name])
        #expect(schema.outPins.map(\.shortcut) == [pwm.output.name])
        #expect(model.systemCommand(of: module)?.command == pwm.command)
        // The simulator runs the chosen variant: its command word is what the core holds on `Cmd`.
        let pins = try #require(model.getNode(id: id)?.block)
        #expect(pins.inPins[1].asInt == Int(pwm.command), "the simulator runs the chosen variant")

        model.setSystemCommand(moduleId: id, to: nil)
        #expect(model.module(id: id)?.rawAttributes["DEFINITION"] == nil)
    }

    @Test("A parameter the command does not use says so instead of reading Par1")
    @MainActor func hiddenParameterIsLabelled() throws {
        let (model, id) = try modelWithSystemCmd()
        let withHidden = try #require(model.systemCommandCatalogue.first { $0.input2.isHidden && !$0.input1.isHidden })
        model.setSystemCommand(moduleId: id, to: withHidden)
        let schema = ModulePinCatalog.pinNames(for: try #require(model.module(id: id)))
        #expect(schema.paramPins[1].shortcut == "I2")
        #expect(schema.paramPins[1].name.hasPrefix("Not used by"))
    }
}

extension SystemCmdEditingTests {
    @Test("A new SystemCmd sends 0x0302, has two parameters, and a parameter can be set")
    @MainActor func newBlockDefaults() throws {
        let (model, id) = try modelWithSystemCmd()
        let module = try #require(model.module(id: id))
        #expect(module.inPins.count == 2 && module.paramPins.count == 2)
        #expect(module.inPins[1].value.asInt == 0x0302)
        model.updateModuleParam(id: id, paramIndex: 0, value: .int32(5))
        #expect(model.module(id: id)?.paramPins[0].value.asInt == 5)
        for _ in 0..<5 { model.step() }
        #expect(model.getNode(id: id)?.block.paramPins[0].asInt == 5, "it survives the simulation steps")
    }
}
