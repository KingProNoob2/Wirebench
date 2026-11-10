import Testing
import Foundation
import WirebenchCore
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// Rectangles and circles on the sheet, from the encoding Dirigo stores them in to the document edits
/// the canvas performs.
///
/// The `TYPE` numbers are the original's `TPCCProjectGraphicsType` ordinals, not a guess — see
/// `PCCGraphicBuilder.Kind` for the evidence and `graphicTypesInTheCorpusAreAllKnown` for the check
/// that keeps them honest against real files.
@Suite("Graphic shapes")
struct GraphicShapeTests {

    /// Collapses whitespace so markup can be compared regardless of indentation.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var project: PCCProject {
        var project = PCCProject(name: "shapes")
        project.pages = [ProjectPage(caption: "List 1")]
        return project
    }

    @Test("A rectangle is written as two corner nodes with a pen and a brush")
    func rectangleMarkup() {
        var project = project
        project.graphics = [PCCGraphicBuilder.shape(
            .rectangle, in: GraphicBox(x: 100, y: 200, width: 300, height: 150), page: "List 1")]

        let xml = normalized(PCCSerializer().serialize(project: project))
        let expected = normalized("""
        <GRAPHICS TYPE="2" PAGE="List 1">
          <NODES>
            <NODE X="100" Y="200"/>
            <NODE X="400" Y="350"/>
          </NODES>
          <PEN COLOR="$000000" MODE="4" STYLE="0" WIDTH="1"/>
          <BRUSH COLOR="$FFFFFF" STYLE="1"/>
        </GRAPHICS>
        """)
        #expect(xml.contains(expected), "built shape does not match the encoding:\n\(xml.suffix(500))")
    }

    @Test("Both kinds survive a save and are byte-identical on the second pass")
    func shapesRoundTrip() throws {
        var project = project
        project.graphics = [
            PCCGraphicBuilder.shape(.rectangle, in: GraphicBox(x: 40, y: 60, width: 200, height: 120),
                                    page: "List 1"),
            PCCGraphicBuilder.shape(.ellipse, in: GraphicBox(x: 300, y: 60, width: 120, height: 120),
                                    page: "List 1"),
        ]
        let xml = PCCSerializer().serialize(project: project)
        let reparsed = try PCCParser().parse(xmlString: xml)

        #expect(reparsed.graphics.count == 2)
        #expect(reparsed.graphics.map(\.type) == [PCCGraphicBuilder.Kind.rectangle.rawValue,
                                                  PCCGraphicBuilder.Kind.ellipse.rawValue],
                "a rectangle is TYPE 2 and an ellipse TYPE 3, or Dirigo reads them as the other")
        #expect(reparsed.graphics.map(\.boundingBox).compactMap { $0 } ==
                [GraphicBox(x: 40, y: 60, width: 200, height: 120),
                 GraphicBox(x: 300, y: 60, width: 120, height: 120)],
                "the box comes back out of the two corners exactly as it went in")
        #expect(reparsed.graphics[0].penColor == "$000000")
        #expect(reparsed.graphics[0].brushStyle == 1)
        #expect(PCCSerializer().serialize(project: reparsed) == xml)
    }

    @Test("A shape read from a file moves in the file, not only on the screen")
    func movesAFileLoadedShape() throws {
        // What Dirigo would write for a rectangle: the same children a text object carries, so the
        // verbatim subtree is what the serializer prefers, and it has to follow the new box.
        let original = """
        <PCC_PROJECT NAME="shapes">
          <PAGES><PAGE CAPTION="List 1"/></PAGES>
          <MODULES/>
          <CONNECTIONS/>
          <PROJECT_GRAPHICS>
            <GRAPHICS TYPE="2" PAGE="List 1">
              <NODES>
                <NODE X="100" Y="100"/>
                <NODE X="200" Y="160"/>
              </NODES>
              <PEN COLOR="$000080" MODE="4" STYLE="0" WIDTH="3"/>
              <BRUSH COLOR="$FFFFFF" STYLE="0"/>
            </GRAPHICS>
          </PROJECT_GRAPHICS>
        </PCC_PROJECT>
        """
        let parsed = try PCCParser().parse(xmlString: original)
        var moved = parsed
        moved.graphics[0].setBoundingBox(GraphicBox(x: 150, y: 120, width: 250, height: 300))
        let xml = PCCSerializer().serialize(project: moved)

        #expect(xml.contains(#"<NODE X="150" Y="120"/>"#), "the new first corner was not written:\n\(xml)")
        #expect(xml.contains(#"<NODE X="400" Y="420"/>"#), "the new far corner was not written:\n\(xml)")
        #expect(xml.contains(#"COLOR="$000080" MODE="4" STYLE="0" WIDTH="3""#),
                "the pen that came from the file has to stay as it was")
    }

    @Test("A box dragged backwards still describes the rectangle it covers")
    func normalizesADraggedBox() {
        let dragged = GraphicBox(x: 300, y: 400, width: -120, height: -80)
        #expect(dragged.normalized() == GraphicBox(x: 180, y: 320, width: 120, height: 80))
        #expect(dragged.resized(maxX: 100, maxY: 100).width >= 0)
        #expect(GraphicBox(x: 10, y: 10, width: 50, height: 40).corners ==
                [RoutePoint(x: 10, y: 10), RoutePoint(x: 60, y: 50)])
    }

    @Test("A shape whose corners are missing is not drawn at a guessed position")
    func refusesToGuessAGeometry() {
        let oneCorner = ProjectGraphic(type: PCCGraphicBuilder.Kind.rectangle.rawValue, page: "List 1",
                                       nodes: [RoutePoint(x: 10, y: 20)])
        #expect(oneCorner.isShape)
        #expect(oneCorner.boundingBox == nil)

        let line = ProjectGraphic(type: PCCGraphicBuilder.Kind.line.rawValue, page: "List 1",
                                  nodes: [RoutePoint(x: 10, y: 20), RoutePoint(x: 30, y: 40)])
        #expect(!line.isShape, "a line has nodes too, but no box")
    }

    /// The `TYPE` numbers are a contract with another program, so they are pinned outright. Dirigo
    /// reads `TYPE="2"` as a `TPCCRectangle` and `TYPE="3"` as a `TPCCEllipse`, and a swap here is
    /// invisible to every other test in this file: the app stays self-consistent either way, writing
    /// the same numbers it reads back.
    @Test("The graphic type numbers are the original's ordinals")
    func kindNumbersMatchTheOriginal() {
        #expect(PCCGraphicBuilder.Kind.line.rawValue == 1)       // pgtLine
        #expect(PCCGraphicBuilder.Kind.rectangle.rawValue == 2)  // pgtRectangle
        #expect(PCCGraphicBuilder.Kind.ellipse.rawValue == 3)    // pgtEllipse
        #expect(PCCGraphicBuilder.Kind.text.rawValue == 4)       // pgtText
    }

}

@MainActor
@Suite("Graphic shapes on the sheet")
struct GraphicShapeEditingTests {

    private func makeModel() throws -> AppModel {
        var project = PCCProject(name: "shapes")
        project.pages = [ProjectPage(caption: "main"), ProjectPage(caption: "other")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        // The positions below are exact, and snapping is a user preference this process inherits.
        model.snapToGrid = false
        return model
    }

    @Test("Adding a rectangle centres it on the given point and selects it")
    func addsRectangle() throws {
        let model = try makeModel()
        let index = try #require(model.addShape(.rectangle, at: CGPoint(x: 400, y: 300)))

        let graphic = model.project!.graphics[index]
        #expect(graphic.type == PCCGraphicBuilder.Kind.rectangle.rawValue)
        #expect(graphic.page == "main")
        #expect(graphic.boundingBox == GraphicBox(x: 304, y: 236, width: 192, height: 128))
        #expect(model.selectedAnnotationIndex == index)
        #expect(model.editingAnnotationIndex == nil, "a shape has nothing to type into")
        #expect(model.shapes(onPage: "main").map(\.index) == [index])
        #expect(model.shapes(onPage: "other").isEmpty)
    }

    @Test("A new circle is square, so Dirigo draws it as one")
    func addsCircle() throws {
        let model = try makeModel()
        let index = try #require(model.addShape(.ellipse, at: CGPoint(x: 100, y: 100)))
        let box = try #require(model.project!.graphics[index].boundingBox)
        #expect(box.width == box.height)
    }

    /// The inspector's door for a drawn object's stored fields. Pen, brush and font are ordinary
    /// document bytes, so editing them is a document edit — and writing the value a field already has
    /// is not one, or merely opening the inspector would mark the project unsaved.
    @Test("The inspector edits a shape's stored fields, and a no-op is not an edit")
    func inspectorEditsShapeFields() throws {
        let model = try makeModel()
        let index = try #require(model.addShape(.rectangle, at: CGPoint(x: 400, y: 300)))
        model.isDocumentEdited = false

        model.updateGraphic(at: index) { $0.penWidth = 3 }
        #expect(model.project!.graphics[index].penWidth == 3)
        #expect(model.isDocumentEdited)

        model.isDocumentEdited = false
        model.updateGraphic(at: index) { $0.penWidth = 3 }
        #expect(!model.isDocumentEdited, "writing the value it already has is not an edit")

        model.updateGraphic(at: index) { $0.brushStyle = 0 }
        #expect(model.project!.graphics[index].brushStyle == 0, "a solid fill is style 0 in the file")
    }

    @Test("The inspector edits a text object's type the same way")
    func inspectorEditsTextFields() throws {
        let model = try makeModel()
        let index = try #require(model.addTextAnnotation("Label", at: CGPoint(x: 200, y: 200)))

        model.updateGraphic(at: index) { $0.fontSize = 20; $0.fontBold = true }
        let graphic = model.project!.graphics[index]
        #expect(graphic.fontSize == 20)
        #expect(graphic.fontBold == true)
        #expect(graphic.text == "Label", "editing the type must not touch the text")
    }

    @Test("Two shapes added at the same spot do not stack exactly")
    func offsetsRepeatInsertions() throws {
        let model = try makeModel()
        let first = try #require(model.addShape(.rectangle, at: CGPoint(x: 400, y: 300)))
        let second = try #require(model.addShape(.rectangle, at: CGPoint(x: 400, y: 300)))

        let a = try #require(model.project!.graphics[first].boundingBox)
        let b = try #require(model.project!.graphics[second].boundingBox)
        #expect(a != b, "the second one has to be grabbable on its own")
    }

    @Test("Moving and resizing write a new box, and a drag that goes nowhere writes nothing")
    func movesAndResizes() throws {
        let model = try makeModel()
        let index = try #require(model.addShape(.rectangle, at: CGPoint(x: 400, y: 300)))
        let original = try #require(model.project!.graphics[index].boundingBox)

        #expect(!model.updateShape(at: index, to: original),
                "a drag that ends where it started must not add an undo step")

        #expect(model.updateShape(at: index, to: original.offsetBy(dx: 64, dy: 32)))
        #expect(model.project!.graphics[index].boundingBox == original.offsetBy(dx: 64, dy: 32))

        // Shrinking past the minimum leaves a shape that can still be clicked.
        #expect(model.updateShape(at: index, to: GraphicBox(x: original.x + 64, y: original.y + 32,
                                                            width: 2, height: 2)))
        let floor = try #require(model.project!.graphics[index].boundingBox)
        #expect(floor.width == AppModel.minimumShapeSize && floor.height == AppModel.minimumShapeSize)
    }

    @Test("A group drag moves every member by the same delta")
    func movesAGroup() throws {
        let model = try makeModel()
        let a = try #require(model.addShape(.rectangle, at: CGPoint(x: 200, y: 200)))
        let b = try #require(model.addShape(.ellipse, at: CGPoint(x: 700, y: 500)))
        let beforeA = try #require(model.project!.graphics[a].boundingBox)
        let beforeB = try #require(model.project!.graphics[b].boundingBox)

        model.selectedAnnotationIndex = a
        model.selectedAnnotationIndices = [a, b]
        model.moveShapes([a, b], lead: a, deltaX: 96, deltaY: 48)

        #expect(model.project!.graphics[a].boundingBox == beforeA.offsetBy(dx: 96, dy: 48))
        #expect(model.project!.graphics[b].boundingBox == beforeB.offsetBy(dx: 96, dy: 48),
                "spacing inside a group has to survive the move")
    }

    @Test("Geometry edits never touch a text object")
    func refusesTextObjects() throws {
        let model = try makeModel()
        let text = try #require(model.addTextAnnotation("A", at: CGPoint(x: 50, y: 60)))
        let node = model.project!.graphics[text].nodes.first

        #expect(!model.updateShape(at: text, to: GraphicBox(x: 0, y: 0, width: 100, height: 100)))
        #expect(model.project!.graphics[text].nodes.first == node, "the text stayed where it was")
        model.moveShapes([text], lead: text, deltaX: 100, deltaY: 100)
        #expect(model.project!.graphics[text].nodes.first == node)
    }

    @Test("Deleting the selected shape removes it through the shared selection")
    func deletesSelectedShape() throws {
        let model = try makeModel()
        _ = try #require(model.addShape(.rectangle, at: CGPoint(x: 300, y: 300)))
        #expect(model.project!.graphics.count == 1)

        model.deleteSelectedAnnotation()
        #expect(model.project!.graphics.isEmpty, "the shared selection deletes a shape as it does text")
        #expect(model.selectedAnnotationIndex == nil)
    }

    @Test("Adding a shape is one undo step")
    func undoBringsAShapeBack() throws {
        let model = try makeModel()
        _ = try #require(model.addShape(.rectangle, at: CGPoint(x: 300, y: 300)))
        #expect(model.project!.graphics.count == 1)

        model.undo()
        #expect(model.project!.graphics.isEmpty, "the add was the only edit, so one step undoes it")

        model.redo()
        #expect(model.project!.graphics.count == 1)
        #expect(model.project!.graphics[0].isShape)
    }

    @Test("A shape on the other page is not deleted by the shown page's selection")
    func guardsOtherPage() throws {
        let model = try makeModel()
        let index = try #require(model.addShape(.rectangle, at: CGPoint(x: 300, y: 300)))
        model.selectedPage = "other"
        model.selectedAnnotationIndex = index

        model.deleteSelectedAnnotation()
        #expect(model.project!.graphics.count == 1, "invisible objects cannot be deleted by accident")
    }

    /// The behaviour the wrong numbers cost, rather than the numbers themselves.
    ///
    /// `ehhhhhh zelznice.pcc` holds sixteen rectangles and three circles on its main page. While
    /// `Kind.rectangle` was 3 and `Kind.ellipse` was 5, `isShape` was false for every `TYPE="2"`
    /// object, so the canvas drew none of the sixteen — a sheet full of boxes looked bare, and the
    /// three real circles were drawn as rectangles. Nothing else could see it: the file still
    /// round-tripped byte-for-byte, because `TYPE` is written back verbatim.
    @Test("A real project's boxes are shapes the canvas draws")
    func drawsTheCorpusShapes() throws {
        // Required, not skipped: a vacuous pass here is exactly the failure this test exists to catch.
        // The name has six `h`s, which is not how the docs spell it — `TestCorpus.existing` returns nil
        // for a name that is one character out, and a skipped test looks identical to a passing one.
        let url = try #require(TestCorpus.existing("ehhhhhh zelznice.pcc"),
                               "the corpus should be on disk; see TestCorpus.directories")
        let model = AppModel()
        model.loadProject(url: url)
        model.selectedPage = "Main"

        let project = try #require(model.project)
        let onMain = project.graphics.filter { $0.page == "Main" }
        let shapes = model.shapes(onPage: "Main")
        let rectangles = shapes.filter { $0.graphic.objectKind == .rectangle }
        let ellipses = shapes.filter { $0.graphic.objectKind == .ellipse }

        #expect(!onMain.isEmpty, "the corpus project should have graphics on its main page")
        #expect(rectangles.count == onMain.filter { $0.type == 2 }.count,
                "every TYPE=\"2\" object Dirigo drew as a box must reach the canvas")
        #expect(ellipses.count == onMain.filter { $0.type == 3 }.count,
                "every TYPE=\"3\" object must reach the canvas, and as an ellipse")
        #expect(rectangles.count > ellipses.count,
                "sanity: this sheet is mostly boxes — found \(rectangles.count) and \(ellipses.count)")
    }
}
