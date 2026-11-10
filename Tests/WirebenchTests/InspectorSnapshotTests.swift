#if canImport(SwiftUI)
// Tests of the SwiftUI views: the app target exists only where SwiftUI does.
import Testing
import Foundation
import SwiftUI
import AppKit
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// Renders the inspector offscreen so a visual change can be looked at without launching the app.
///
/// Gated on `WIREBENCH_SNAPSHOT`: it writes files rather than asserting anything, so it is not a test of
/// behaviour, and a normal `swift test` run skips it. Materials and glass are drawn by the window server,
/// so a render like this shows the layout and typography faithfully and the translucency roughly.
@Suite("Inspector snapshot")
struct InspectorSnapshotTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A binding that behaves like the model's.
    ///
    /// Note that `ImageRenderer` draws a `TextField` as a disabled placeholder — the yellow bars — so an
    /// offscreen render cannot show the editable input rows as they really look. Everything else in the
    /// panel renders faithfully; the field widths have to be judged on screen.
    @MainActor
    static func editable(_ value: Int) -> Binding<Int> {
        Binding(get: { value }, set: { _ in })
    }

}

@Suite("Inspector rows belong to their block")
struct InspectorRowIdentityTests {
    @Test("The same-looking row on another block, or another pin, is not the same row")
    @MainActor func rowsAreNotEqualAcrossOwners() {
        let first = SignalRow(name: "X (Value)", value: "0", isHigh: false, isInput: true, owner: 1, pin: 0)
        #expect(first == SignalRow(name: "X (Value)", value: "0", isHigh: false, isInput: true, owner: 1, pin: 0))
        #expect(first != SignalRow(name: "X (Value)", value: "0", isHigh: false, isInput: true, owner: 2, pin: 0),
                "selecting another block must rebuild the row, or its closures keep writing to the old one")
        #expect(first != SignalRow(name: "X (Value)", value: "0", isHigh: false, isInput: true, owner: 1, pin: 1))
    }
}
#endif
