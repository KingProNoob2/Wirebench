import Testing
import Foundation

@Suite("Qt frontend consistency")
struct FrontendParityTests {
    private func qml(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("qt/qml/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Build and upload has one ampersand in its visible label")
    func buildUploadLabel() throws {
        let source = try qml("BuildDialog.qml")
        #expect(!source.contains("Build && upload"))
    }

    @Test("The File menu offers Maraflow export as well as legacy PCC export")
    func maraflowExportIsInMainMenu() throws {
        let source = try qml("MainMenu.qml")
        #expect(source.contains("{id: \"exportMfl\""))
    }
}
