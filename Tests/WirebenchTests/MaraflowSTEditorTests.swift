import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// A pure-ST Maraflow project opens with its source in the Structured Text editor, not just an empty sheet.
@Suite("Maraflow ST editor")
struct MaraflowSTEditorTests {
    @MainActor
    @Test("Loading a pure ST page fills the editor and Apply writes it back")
    func loadsAndAppliesSource() throws {
        let code = """
        VAR_INPUT
            bRun : BOOL := TRUE;
        END_VAR
        VAR_OUTPUT
            bLed : BOOL;
        END_VAR
        bLed := bRun;
        """
        let xml = """
        <properties>
        <entry key="project.name">PureST</entry>
        <entry key="project.pageCount">1</entry>
        <entry key="page.0.name">Main_ST</entry>
        <entry key="page.0.language">ST</entry>
        <entry key="page.0.stCode">\(code)</entry>
        <entry key="page.0.stThreadId">2</entry>
        <entry key="page.0.blockCount">0</entry>
        <entry key="page.0.wireCount">0</entry>
        </properties>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pure-st-\(UUID()).mfl")
        try Data(xml.utf8).write(to: url)
        let model = AppModel()
        model.loadProject(url: url)
        #expect(model.maraflowSTPageIndex == 0)
        #expect(model.swiftSource.contains("bLed := bRun;"))
        #expect(model.maraflowSTCode()?.contains("bLed := bRun;") == true)

        let edited = code.replacingOccurrences(of: "bLed := bRun;", with: "bLed := NOT bRun;")
        model.swiftSource = edited
        model.applyMaraflowSTCode(edited)
        let module = try #require(model.project?.modules.first { $0.guid == MaraflowStPage.guid })
        #expect(module.rawAttributes["MARAFLOW_ST_CODE"] == edited)
        #expect(model.project?.maraflow?.properties["page.0.stCode"] == edited)
        #expect(model.maraflowSTCode() == edited)
    }
}
