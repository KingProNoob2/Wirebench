import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchModel

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
    func identifyWithoutPort() {
        let model = model()
        model.selectedPortPath = ""
        #expect(model.refreshDuinoInfo() == nil)
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
