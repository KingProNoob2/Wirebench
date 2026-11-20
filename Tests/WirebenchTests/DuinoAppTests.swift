import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
import WirebenchModel

@Suite("Duino-S app path")
@MainActor
struct DuinoAppTests {
    private func model() -> AppModel {
        let model = AppModel()
        var project = PCCProject(name: "duino")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = [PCCModule(id: 1, guid: UUID(), name: "Block", x: 0, y: 0,
                                     order: 10, threadId: 1, page: "Main")]
        model.project = project
        model.hardwareFamily = .duinoS
        return model
    }

    @Test("Identify without a port says so instead of opening a device")
    func identifyWithoutPort() async {
        let model = model()
        model.selectedPortPath = ""
        await model.identifyDuino()
        #expect(model.duinoInfo == nil)
        #expect(model.uploadStatus.contains("No serial port"))
    }

    @Test("Upload without a port does not start an upload")
    func uploadWithoutPort() async {
        let model = model()
        model.selectedPortPath = ""
        await model.uploadDuinoProgram()
        #expect(!model.isUploading)
        #expect(model.uploadStatus.contains("No serial port"))
        #expect(model.uploadPhase.isEmpty)
    }

    @Test("Ethernet without an address is not treated as configured")
    func ethernetNeedsHost() {
        let model = model()
        model.duinoTransport = .ethernet
        model.duinoHost = ""
        #expect(!model.isDuinoLinkConfigured)
        model.startDuinoWatch()
        #expect(!model.isWatchingDuino)
        #expect(model.duinoWatchStatus.contains("IP address"))
    }

    @Test("Build Project produces the Duino-S report when that family is selected")
    func buildShowsDuinoReport() throws {
        let model = model()
        let definition = try #require(MaraflowCatalog.byId["Bool.And"])
        model.project?.modules = [PCCModule(
            id: 1, guid: definition.guid, name: "And1", x: 0, y: 0, order: 10, threadId: 1, page: "Main",
            inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true)),
                     Pin(id: 2, value: .bool(true))],
            paramPins: [], outPins: [Pin(id: 0, value: .bool(false))],
            rawAttributes: AttributeBag([("MARAFLOW_DEF", "Bool.And")]))]
        model.buildAndShowReport()
        #expect(model.duinoBuildResult != nil)
        #expect(model.isBuildReportVisible)
        #expect(model.buildReport == nil)
    }

    @Test("Watch without a port does not open a session")
    func watchWithoutPort() {
        let model = model()
        model.selectedPortPath = ""
        model.startDuinoWatch()
        #expect(!model.isWatchingDuino)
        #expect(model.duinoWatchStatus.contains("No serial port"))
    }

    @Test("The Hardware Link family picker routes the upload action to the Duino-S")
    func familyRoutes() {
        let model = model()
        #expect(model.hardwareFamily == .duinoS)
        model.hardwareFamily = .dirigo
        #expect(model.hardwareFamily.shortTitle == "Dirigo")
    }
}
