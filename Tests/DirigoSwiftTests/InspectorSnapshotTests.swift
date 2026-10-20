import Testing
import Foundation
import SwiftUI
import AppKit
@testable import DirigoApp

/// Renders the inspector offscreen so a visual change can be looked at without launching the app.
///
/// Gated on `DIRIGO_SNAPSHOT`: it writes files rather than asserting anything, so it is not a test of
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

    @Test("Render the inspector, light and dark", .enabled(if: ProcessInfo.processInfo.environment["DIRIGO_SNAPSHOT"] != nil))
    @MainActor
    func render() throws {
        let url = Self.root.appendingPathComponent("had+1block.pcc")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        for scheme in [ColorScheme.dark, .light] {
            let model = AppModel()
            model.loadProject(url: url)
            // `Counter1`: a block with both inputs and outputs, and the two hero actions.
            model.selectedModuleId = 3

            // The header and a few signal rows, which is the part of the panel the screenshot shows. A
            // grouped `Form` has no layout outside a window, so rendering the pieces is what works; the
            // header's container is the form row, so here it is drawn on the panel colour instead.
            let view = VStack(alignment: .leading, spacing: 10) {
                InspectorHero(name: "Counter1",
                              blockName: "Counter",
                              category: "Main\\Other",
                              summary: "Increases Y by Step on Trigger 0->1 event",
                              symbol: InspectorView.iconForBlockType("Counter"),
                              tint: Theme.tint(forCategory: "Main\\Other"),
                              isSimulated: true,
                              onToggleFirstInput: {},
                              onReset: {})
                .padding(.horizontal, 16)   // stands in for the grouped form's row inset
                VStack(spacing: 6) {
                    // A plain value row (an output) and an editable integer row (an input), which is
                    // where the spacing question is.
                    SignalRow(name: "Y (Count)", value: "1", isHigh: true).equatable()
                    // A real binding, not `.constant`: SwiftUI draws a constant binding as a disabled
                    // field, which is not what the app shows.
                    SignalRow(name: "En (Enabled)", value: "1", isHigh: true, onToggle: {}, number: Self.editable(1)).equatable()
                    SignalRow(name: "Sw (Switch)", value: "6", isHigh: true, onToggle: {}, number: Self.editable(6)).equatable()
                    SignalRow(name: "X7 (Input 7)", value: "128", isHigh: true, onToggle: {}, number: Self.editable(128)).equatable()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .frame(width: 320)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.95))

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record(ProgramBuilderTests.Mismatch(description: "ImageRenderer produced nothing"))
                return
            }
            let name = scheme == .dark ? "/tmp/dirigo-inspector-dark.png" : "/tmp/dirigo-inspector-light.png"
            try png.write(to: URL(fileURLWithPath: name))
        }

        // The editable rows are deliberately *not* measured here. `ImageRenderer` cannot draw a
        // `TextField`, and it renders a stateful cell inconsistently — the same row came out as a
        // placeholder, then as an empty 48 pt cell, for the same input. A measurement taken through it
        // would be a number about the renderer, not about the layout.
        //
        // The height guarantee is structural instead, and in `SignalRow`: at rest an editable value is the
        // *same `Text`* as a read-only one, so the two rows cannot lay out differently; the field exists
        // only while the row is being edited. That is the fix for rows that were twice the height of the
        // read-only ones, and it needs no renderer to be true.
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
