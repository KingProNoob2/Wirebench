import Testing
import Foundation
import DirigoCore
import DirigoLibrary

/// Extra properties exist so a block can be improved here without giving up compatibility with the
/// original Dirigo. These tests pin both halves of that promise: the extras survive this app's own
/// saving, and export always produces something Dirigo can read.
@Suite("Extra properties")
struct ExtraPropertyTests {

    private func project(extras: [(String, ExtraPropertyValue)] = []) -> PCCProject {
        var project = PCCProject(name: "extras")
        project.pages = [ProjectPage(caption: "main")]
        var module = PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1",
                               x: 10, y: 20, order: 10, threadId: 1, page: "main",
                               inPins: [Pin(id: 0, value: .bool(true))],
                               outPins: [Pin(id: 0, value: .int32(0))])
        for (name, value) in extras { module.setExtraProperty(name, value) }   // order is meaningful
        project.modules = [module]
        return project
    }

    @Test("A project with no extra properties is not touched by export")
    func noExtrasIsANoOp() {
        let input = project()
        let result = ExtraPropertyTranslator.translate(input)
        #expect(result.notes.isEmpty, "an untouched project must export without comment")
        #expect(result.project.modules == input.modules)
        // The compatibility guarantee in its strongest form: byte-identical output.
        #expect(PCCSerializer().serialize(project: result.project)
                == PCCSerializer().serialize(project: input))
    }

    @Test("Extras survive this app's own save and load, byte for byte")
    func extrasRoundTripInOurFormat() throws {
        let input = project(extras: [("RampTime", .int(1500)), ("Label", .string("fast"))])
        let xml = PCCSerializer().serialize(project: input)
        let reparsed = try PCCParser().parse(xmlString: xml)

        #expect(reparsed.modules[0].extraProperty("RampTime") == .int(1500))
        #expect(reparsed.modules[0].extraProperty("Label") == .string("fast"))
        #expect(reparsed.modules[0].extraPropertyNames == ["RampTime", "Label"], "attribute order is kept")
        // An integer must not come back as "1500.0" or as a string.
        #expect(reparsed.modules[0].rawAttributes["X_RampTime"] == "1500")
        #expect(PCCSerializer().serialize(project: reparsed) == xml, "our own round-trip stays byte-identical")
    }

    @Test("A declared counterpart is written as the Dirigo attribute it names")
    func declaredCounterpartIsTranslated() {
        let declaration = ExtraPropertyDeclaration(
            name: "RampTime", type: .int, defaultValue: .int(0),
            counterpart: .dirigoAttribute("TI", transform: { value in
                value.doubleValue.map { String($0 / 1000) }      // milliseconds here, seconds there
            }),
            summary: "Edge ramp time")
        let result = ExtraPropertyTranslator.translate(
            project(extras: [("RampTime", .int(1500))]),
            declarations: [PulseGenBlock.guid: [declaration]])

        let module = result.project.modules[0]
        #expect(module.rawAttributes["TI"] == "1.5")
        #expect(module.rawAttributes["X_RampTime"] == nil, "the extra must not survive as well as its translation")
        #expect(result.notes == ["PulseGen1: RampTime → TI"])
    }

    @Test("An undeclared extra is removed on export and reported")
    func undeclaredIsDropped() {
        let result = ExtraPropertyTranslator.translate(project(extras: [("Mystery", .int(7))]))
        #expect(result.project.modules[0].rawAttributes["X_Mystery"] == nil)
        #expect(result.project.modules[0].extraPropertyNames.isEmpty)
        #expect(result.notes == ["PulseGen1: removed Mystery — no Dirigo counterpart"])
        // Nothing of ours may be left in a file handed to Dirigo unless it was declared `keep`.
        #expect(!PCCSerializer().serialize(project: result.project).contains("X_"))
    }

    @Test("The keep policy leaves an undeclared extra in the file")
    func keepPolicyPreserves() {
        let result = ExtraPropertyTranslator.translate(project(extras: [("Mystery", .int(7))]),
                                                       defaultPolicy: .keep)
        #expect(result.project.modules[0].extraProperty("Mystery") == .int(7))
        #expect(result.notes == ["PulseGen1: kept Mystery (undeclared)"])
    }

    @Test("A value with no counterpart is dropped rather than written wrong")
    func nilTransformDropsTheValue() {
        let declaration = ExtraPropertyDeclaration(
            name: "Mode", type: .string, defaultValue: .string(""),
            counterpart: .dirigoAttribute("MODE", transform: { value in
                value.encoded == "auto" ? "1" : nil          // Dirigo only has the one mode
            }),
            summary: "Operating mode")
        let declarations = [PulseGenBlock.guid: [declaration]]

        let translated = ExtraPropertyTranslator.translate(project(extras: [("Mode", .string("auto"))]),
                                                          declarations: declarations)
        #expect(translated.project.modules[0].rawAttributes["MODE"] == "1")

        let refused = ExtraPropertyTranslator.translate(project(extras: [("Mode", .string("turbo"))]),
                                                       declarations: declarations)
        #expect(refused.project.modules[0].rawAttributes["MODE"] == nil, "must not invent a mapping")
        #expect(refused.project.modules[0].rawAttributes["X_Mode"] == nil, "and must not leave it behind")
        #expect(refused.notes == ["PulseGen1: removed Mode — its value has no Dirigo equivalent"])
    }

    @Test("Declarations are found by GUID, so renaming an instance keeps them")
    func declarationsFollowTheGuid() {
        let declaration = ExtraPropertyDeclaration(
            name: "RampTime", type: .int, defaultValue: .int(0),
            counterpart: .dirigoAttribute("TI"), summary: "")
        var renamed = project(extras: [("RampTime", .int(250))])
        renamed.modules[0].name = "SomethingElse"

        let result = ExtraPropertyTranslator.translate(renamed, declarations: [PulseGenBlock.guid: [declaration]])
        #expect(result.project.modules[0].rawAttributes["TI"] == "250")
        #expect(result.notes == ["SomethingElse: RampTime → TI"])
    }

    @Test("The shipping catalog is consistent with the block catalog it keys on")
    func shippingCatalogResolves() {
        // An entry naming a block that does not exist would silently never be applied.
        for (blockName, _) in ExtraPropertyCatalog.declared {
            #expect(BlockTypeCatalog.byName[blockName] != nil,
                    "\(blockName) is not a catalogued block name")
        }
        #expect(ExtraPropertyCatalog.byGuid.count == ExtraPropertyCatalog.declared.count)
    }
}
