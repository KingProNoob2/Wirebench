import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// The hidden ST/LD page runtime is not a block on the sheet.
@Suite("Maraflow page runtime")
struct MaraflowPageRuntimeTests {
    @Test("ST and ladder pages are runtime modules, not counted blocks")
    func runtimeModulesAreHidden() throws {
        var entries: [(String, String)] = [
            ("project.name", "Pages"),
            ("project.pageCount", "2"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stThreadId", "0"),
            ("page.0.stCode", "VAR n : INT := 0; END_VAR n := n + 1;"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Relays"),
            ("page.1.language", "LD"),
            ("page.1.rungCount", "1"),
            ("page.1.rung.0.threadId", "2"),
            ("page.1.rung.0.order", "10"),
            ("page.1.rung.0.mainCount", "1"),
            ("page.1.rung.0.main.0.kind", "NO_CONTACT"),
            ("page.1.rung.0.main.0.operand", "DI0"),
            ("page.1.rung.0.coilCount", "1"),
            ("page.1.rung.0.coil.0.kind", "NORMAL_COIL"),
            ("page.1.rung.0.coil.0.operand", "DO0"),
        ]
        let imported = try ProjectFile.read(data: MaraflowImportTests.propertiesXML(entries), filename: "pages")
        let st = try #require(imported.project.modules.first { $0.guid == MaraflowStPage.guid })
        let ld = try #require(imported.project.modules.first { $0.guid == MaraflowLdPage.guid })
        #expect(BlockRole.isMaraflowPageRuntime(st))
        #expect(BlockRole.isMaraflowPageRuntime(ld))
        #expect(st.threadId >= 1, "thread 0 is clamped to a real scheduler slot")
        #expect(imported.project.modules.filter { !BlockRole.isMaraflowPageRuntime($0) }.isEmpty,
                "the runtime modules are not sheet blocks")
    }
}
