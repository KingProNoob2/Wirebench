import Testing
import Foundation
import DirigoCore

/// Graphic objects have no documentation, so these tests compare against a *real* project object:
/// the letter "A" that `autoplexer.pcc` contains. If Dirigo's shape were guessed rather than copied,
/// this is where it would show.
@Suite("Graphic objects")
struct GraphicBuilderTests {

    private static let autoplexer = TestCorpus.project(named: "autoplexer.pcc")
            ?? TestCorpus.directories[0].appendingPathComponent("autoplexer.pcc")

    /// Collapses whitespace so markup can be compared regardless of indentation.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("A built text object is written exactly as Dirigo writes one")
    func matchesDirigosEncoding() {
        var project = PCCProject(name: "graphics")
        project.pages = [ProjectPage(caption: "List 1")]
        project.graphics = [PCCGraphicBuilder.text("A", at: RoutePoint(x: 1342, y: 448), page: "List 1")]

        let xml = normalized(PCCSerializer().serialize(project: project))
        let expected = normalized("""
        <GRAPHICS TYPE="4" PAGE="List 1" TEXT="A">
          <NODES>
            <NODE X="1342" Y="448"/>
          </NODES>
          <FONT NAME="Tahoma" BOLD="False" ITALIC="False" UNDERLINE="False" STRIKE_OUT="False" SIZE="8" COLOR="$FF000008" CHARSET="1"/>
        </GRAPHICS>
        """)
        #expect(xml.contains(expected), "built object does not match Dirigo's own:\n\(xml.suffix(400))")
    }

    @Test("The project that really contains text objects still round-trips byte for byte")
    func realProjectWithGraphicsRoundTrips() throws {
        try #require(FileManager.default.fileExists(atPath: Self.autoplexer.path),
                     "autoplexer.pcc is not on this machine")
        let original = try String(contentsOf: Self.autoplexer, encoding: .utf8)
        let project = try PCCParser().parse(xmlString: original)
        // Deliberately no exact counts. This is a file the user edits while working, and it changed
        // under an earlier version of this test — which is a fault in the test, not the code. What
        // has to hold is that whatever the file contains survives a round trip intact.
        #expect(!project.graphics.isEmpty, "the project has graphic objects")
        #expect(PCCSerializer().serialize(project: project) == original)
        for graphic in project.graphics where graphic.type == PCCGraphicBuilder.Kind.text.rawValue {
            #expect(!(graphic.text ?? "").isEmpty, "a text object must carry a character")
        }
    }

    @Test("Text objects keep their character and position through a save")
    func textSurvivesASave() throws {
        var project = PCCProject(name: "graphics")
        project.pages = [ProjectPage(caption: "Main")]
        project.graphics = [
            PCCGraphicBuilder.text("A", at: RoutePoint(x: 10, y: 20), page: "Main"),
            PCCGraphicBuilder.text("B", at: RoutePoint(x: 30, y: 40), page: "Main"),
        ]
        let xml = PCCSerializer().serialize(project: project)
        let reparsed = try PCCParser().parse(xmlString: xml)

        #expect(reparsed.graphics.count == 2)
        #expect(reparsed.graphics.map(\.text) == ["A", "B"])
        #expect(reparsed.graphics[0].nodes.first == RoutePoint(x: 10, y: 20))
        #expect(reparsed.graphics[1].nodes.first == RoutePoint(x: 30, y: 40))
        #expect(PCCSerializer().serialize(project: reparsed) == xml, "byte-identical on the second pass")
    }
}
