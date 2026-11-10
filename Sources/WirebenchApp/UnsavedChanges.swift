import AppKit
import WirebenchModel

/// The quit question, from AppKit's side.
///
/// The Save / Don't Save / Cancel dialog itself is SwiftUI's — `MainView` shows it from
/// `AppModel.pendingUnsavedIntent`, the same way it shows every other alert. What is left here is the
/// only part SwiftUI cannot express: `applicationShouldTerminate` has to answer *synchronously*,
/// before a view can run.
///
/// Rather than hold the request open with `.terminateLater` — which leaves the app waiting for ever if
/// the alert has nowhere to appear, for instance with every window closed — the first request is
/// cancelled and the alert's answer asks again through `quitHandler`. A second request then passes
/// because `isTerminationApproved` is set.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else { return }
        MainActor.assumeIsolated { model.appBecameActive() }
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard let model else { return }
        MainActor.assumeIsolated { model.appResignedActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return MainActor.assumeIsolated {
            // The answer already allowed it: let this request through, and clear the flag so a quit
            // that AppKit still refuses asks again next time rather than quitting without asking.
            if model.isTerminationApproved {
                model.clearTerminationApproval()
                return .terminateNow
            }
            guard !model.shouldTerminateNow() else { return .terminateNow }
            model.quitHandler = { NSApp.terminate(nil) }
            return .terminateCancel
        }
    }
}
