import Testing
import Foundation
import DirigoCore
import DirigoLibrary
@testable import DirigoApp

/// Text objects on the sheet: they could be drawn but not added, selected, edited or deleted. These
/// cover the document side of making them real objects.
@MainActor
@Suite("Sheet text")
struct SheetTextTests {

    private func makeModel() throws -> AppModel {
        var project = PCCProject(name: "text")
        project.pages = [ProjectPage(caption: "main"), ProjectPage(caption: "other")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        try model.loadProject(url: url)
        return model
    }

    @Test("Adding text creates a Dirigo text object on the shown page and opens it for editing")
    func addsText() throws {
        let model = try makeModel()
        let index = model.addTextAnnotation("A", at: CGPoint(x: 40, y: 60))

        #expect(index == 0)
        #expect(model.project?.graphics.count == 1)
        let graphic = model.project!.graphics[0]
        #expect(graphic.type == PCCGraphicBuilder.Kind.text.rawValue)
        #expect(graphic.text == "A")
        #expect(graphic.page == "main")
        #expect(graphic.nodes.first == RoutePoint(x: 40, y: 60))
        #expect(model.selectedAnnotationIndex == 0)
        #expect(model.editingAnnotationIndex == 0, "a new object should be ready to type into")
    }

    @Test("Typing into an object changes the document, and deleting removes it")
    func editsAndDeletes() throws {
        let model = try makeModel()
        model.addTextAnnotation("A", at: CGPoint(x: 0, y: 0))
        model.updateAnnotationText(at: 0, text: "Start")

        #expect(model.project?.graphics[0].text == "Start")
        // The character travels through a save as the TEXT attribute, as Dirigo writes it.
        let xml = PCCSerializer().serialize(project: model.project!)
        let reparsed = try PCCParser().parse(xmlString: xml)
        #expect(reparsed.graphics[0].text == "Start")

        model.deleteAnnotation(at: 0)
        #expect(model.project?.graphics.isEmpty == true)
        #expect(model.selectedAnnotationIndex == nil)
        #expect(model.editingAnnotationIndex == nil)
    }

    @Test("A selection from one page cannot delete an object on another")
    func pageScopedDeletion() throws {
        let model = try makeModel()
        model.addTextAnnotation("A", at: CGPoint(x: 0, y: 0))
        model.selectedAnnotationIndex = 0

        model.selectedPage = "other"
        model.deleteSelectedAnnotation()
        #expect(model.project?.graphics.count == 1, "the object on `main` must survive")

        model.selectedPage = "main"
        model.deleteSelectedAnnotation()
        #expect(model.project?.graphics.isEmpty == true)
    }

    @Test("Only the shown page's text is offered to the canvas")
    func listsOnlyTheShownPage() throws {
        let model = try makeModel()
        model.addTextAnnotation("A", at: CGPoint(x: 0, y: 0))
        model.selectedPage = "other"
        model.addTextAnnotation("B", at: CGPoint(x: 5, y: 5))

        #expect(model.textAnnotations(onPage: "main").map(\.graphic.text) == ["A"])
        #expect(model.textAnnotations(onPage: "other").map(\.graphic.text) == ["B"])
        // The index is the project-wide one, so the canvas can act on the right object.
        #expect(model.textAnnotations(onPage: "other").first?.index == 1)
    }

    @Test("Clearing a text object is refused, because an empty one draws nothing")
    func refusesEmptyText() throws {
        let model = try makeModel()
        model.addTextAnnotation("A", at: CGPoint(x: 0, y: 0))
        model.updateAnnotationText(at: 0, text: "AB")
        #expect(model.project?.graphics[0].text == "AB")

        model.updateAnnotationText(at: 0, text: "")
        #expect(model.project?.graphics[0].text == "AB", "the object must not become invisible")

        // Whitespace is a legitimate character for a label, unlike the empty string.
        model.updateAnnotationText(at: 0, text: " ")
        #expect(model.project?.graphics[0].text == " ")
    }

    @Test("An unrelated edit does not disturb the sheet's text objects")
    func textSurvivesAnUnrelatedEdit() throws {
        // The app re-serialises the whole project on save, so a text object could be collateral
        // damage from an edit that has nothing to do with it. This pins that it is not.
        var project = PCCProject(name: "keep")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .int32(0))]),
        ]
        project.graphics = [
            PCCGraphicBuilder.text("A", at: RoutePoint(x: 10, y: 20), page: "main"),
            PCCGraphicBuilder.text("B", at: RoutePoint(x: 30, y: 40), page: "main"),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)

        let model = AppModel()
        try model.loadProject(url: url)
        model.renameModule(id: 1, name: "Renamed")          // rebuilds the whole runtime

        let after = PCCSerializer().serialize(project: model.project!)
        #expect(after.components(separatedBy: "TYPE=\"4\"").count - 1 == 2, "both text objects must survive")
        #expect(after.contains("TEXT=\"A\"") && after.contains("TEXT=\"B\""))
        #expect(after.contains("Renamed"))

        // And again through a save/load cycle, which is what actually bit us.
        let reparsed = try PCCParser().parse(xmlString: after)
        #expect(reparsed.graphics.count == 2)
        #expect(PCCSerializer().serialize(project: reparsed) == after)
    }
}
