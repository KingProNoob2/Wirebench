import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// A Dirigo graphic can be connected to a module output (`<INPUT>`): the object then paints with its active
/// pen/brush when that output crosses the high threshold.
@Suite("Dirigo graphic output binding")
struct DirigoGraphicBindingTests {
    @Test("The INPUT binding and active colours survive parsing")
    func parsesInputBinding() throws {
        let xml = """
        <PCC_PROJECT NAME="graphic">
          <PROJECT_GRAPHICS>
            <GRAPHICS TYPE="3" PAGE="P1">
              <NODES><NODE X="10" Y="20"/><NODE X="30" Y="40"/></NODES>
              <INPUT IN_MODULE_ID="7" IN_PIN_ID="2" HIGH="1" LOW="0" PEN_COLOR="$0000FF" BRUSH_COLOR="$FF"/>
              <PEN COLOR="$000080" MODE="4" STYLE="0" WIDTH="5"/>
              <BRUSH COLOR="$FFFFFF" STYLE="0"/>
            </GRAPHICS>
          </PROJECT_GRAPHICS>
        </PCC_PROJECT>
        """
        let project = try PCCParser().parse(xmlString: xml)
        let graphic = try #require(project.graphics.first)
        #expect(graphic.inputModuleId == 7)
        #expect(graphic.inputPinId == 2)
        #expect(graphic.highValue == 1)
        #expect(graphic.lowValue == 0)
        #expect(graphic.activePenColor == "$0000FF")
        #expect(graphic.activeBrushColor == "$FF")
        let again = try PCCParser().parse(xmlString: PCCSerializer().serialize(project: project))
        #expect(again.graphics.first?.inputPinId == 2)
        #expect(again.graphics.first?.highValue == 1)
    }

    @Test("Editing or clearing the binding is written back into the INPUT element")
    func serializesBindingChanges() throws {
        let xml = """
        <PCC_PROJECT NAME="graphic">
          <PROJECT_GRAPHICS>
            <GRAPHICS TYPE="2" PAGE="P1">
              <NODES><NODE X="10" Y="20"/><NODE X="30" Y="40"/></NODES>
              <INPUT IN_MODULE_ID="7" IN_PIN_ID="2" HIGH="1"/>
              <PEN COLOR="$000000" MODE="4" STYLE="0" WIDTH="1"/>
              <BRUSH COLOR="$FFFFFF" STYLE="0"/>
            </GRAPHICS>
          </PROJECT_GRAPHICS>
        </PCC_PROJECT>
        """
        var project = try PCCParser().parse(xmlString: xml)
        project.graphics[0].inputPinId = 4
        project.graphics[0].highValue = 7
        project.graphics[0].activeBrushColor = "$00FF00"
        let edited = try PCCParser().parse(xmlString: PCCSerializer().serialize(project: project))
        #expect(edited.graphics.first?.inputPinId == 4)
        #expect(edited.graphics.first?.highValue == 7)
        #expect(edited.graphics.first?.activeBrushColor == "$00FF00")

        project.graphics[0].inputModuleId = nil
        project.graphics[0].inputPinId = nil
        let cleared = try PCCParser().parse(xmlString: PCCSerializer().serialize(project: project))
        #expect(cleared.graphics.first?.inputModuleId == nil)
    }

    @MainActor
    @Test("A connected graphic is active while its output is high")
    func followsOutput() throws {
        var project = PCCProject(name: "lamp")
        project.pages = [ProjectPage(caption: "main")]
        let lamp = BlockFactory.makeModule(guid: BoolVarBlock.guid, id: 1, name: "Lamp", x: 40, y: 40,
                                           order: 10, threadId: 2, page: "main")
        project.modules = [lamp]
        project.graphics = [ProjectGraphic(type: 3, page: "main",
                                           nodes: [RoutePoint(x: 200, y: 40), RoutePoint(x: 260, y: 100)],
                                           inputModuleId: 1, inputPinId: 0, highValue: 1,
                                           activeBrushColor: "$FF")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-\(UUID()).wbp")
        try WirebenchDocument.encode(project).write(to: url)
        let model = AppModel()
        model.loadProject(url: url)
        let graphic = try #require(model.project?.graphics.first)
        model.setModuleOutput(moduleId: 1, pinIndex: 0, value: .bool(false))
        #expect(model.graphicIsActive(graphic) == false)
        model.setModuleOutput(moduleId: 1, pinIndex: 0, value: .bool(true))
        #expect(model.graphicIsActive(graphic) == true)
    }
}
