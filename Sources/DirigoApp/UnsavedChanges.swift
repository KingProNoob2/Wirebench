import AppKit
import UniformTypeIdentifiers

/// The Save / Don't Save / Cancel question asked before unsaved work would be lost: on Quit, and before *New* or
/// *Open* replaces the project. Only significant changes ask (`AppModel.hasSignificantChanges`), not layout.
enum UnsavedChanges {
    /// `true` when it is fine to go ahead: nothing to lose, saved, or the user chose not to save.
    @MainActor
    static func confirm(_ model: AppModel) -> Bool {
        guard model.hasSignificantChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(model.projectTitle)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(model)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Saves to the project's file, or asks where when it has none. `false` if that was cancelled or failed.
    @MainActor
    private static func save(_ model: AppModel) -> Bool {
        var destination = model.currentFileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pccProject]
            panel.nameFieldStringValue = model.saveAsDefaultName
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        do {
            try model.saveProject(to: destination!)
            return true
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "The project could not be saved."
            failure.runModal()
            return false
        }
    }
}

/// Asks before quitting with unsaved changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return MainActor.assumeIsolated { UnsavedChanges.confirm(model) } ? .terminateNow : .terminateCancel
    }
}
