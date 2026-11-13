import Testing
import Foundation
import CoreGraphics
import WirebenchCore
import WirebenchLibrary
@testable import WirebenchModel

/// The cable in flight and picking a finished one — the two behaviours Qt had that the SwiftUI canvas did not.
///
/// Qt draws the cable being dragged as an **elbow** (a short run out of the pin, across, then into the pointer), snaps
/// its end onto the input pin under the pointer and rings that pin; and a click on a wire **picks** it, in the accent
/// colour and heavier, for Delete to remove. These pin the model half of both: the shape, the snap, and the selection.
@Suite("Wiring against Qt")
@MainActor
struct WireSelectionTests {
    /// A `Not` feeding nothing, and a block with two inputs and two parameters to aim at.
    static func project(wired: Bool = false) -> PCCProject {
        var not = PCCModule(id: 1, guid: NotBlock.guid, name: "Not1", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                            inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                            paramPins: [], outPins: [Pin(id: 0, value: .bool(false))])
        not.x = 0; not.y = 0
        let other = PCCModule(id: 2, guid: AddBlock.guid, name: "Add1", x: 400, y: 0, order: 20, threadId: 1, page: "main",
                              inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(0)), Pin(id: 2, value: .int32(0))],
                              paramPins: [Pin(id: 0, value: .int32(0)), Pin(id: 1, value: .int32(0))],
                              outPins: [Pin(id: 0, value: .int32(0))])
        var project = PCCProject(name: "wiring")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [not, other]
        if wired {
            project.inConnections = [Connection(inModuleId: 2, inPinId: 0, outModuleId: 1, outPinId: 0)]
        }
        return project
    }

    static let ids: Set<Int> = [1, 2]

    // MARK: - Elbow

    @Test("The cable is the elbow Qt draws, with Qt's turn")
    func elbowShape() {
        let start = CGPoint(x: 100, y: 100)
        // Room to the right of the pin: the turn is half way.
        #expect(WirePreview.elbow(from: start, to: CGPoint(x: 300, y: 200), leaving: .output)
                == [start, CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 200)])
        // No room (less than a 36 pt run): Qt's fixed 18 pt stub.
        #expect(WirePreview.elbow(from: start, to: CGPoint(x: 110, y: 200), leaving: .output)
                == [start, CGPoint(x: 118, y: 100), CGPoint(x: 118, y: 200), CGPoint(x: 110, y: 200)])
        // Dragged from an input instead, the cable leaves to the left — the mirror image of the same rule.
        let fromInput = CGPoint(x: 300, y: 100)
        #expect(WirePreview.elbow(from: fromInput, to: CGPoint(x: 100, y: 200), leaving: .input)
                == [fromInput, CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 100, y: 200)])
        #expect(WirePreview.elbow(from: fromInput, to: CGPoint(x: 290, y: 200), leaving: .param)
                == [fromInput, CGPoint(x: 282, y: 100), CGPoint(x: 282, y: 200), CGPoint(x: 290, y: 200)])
    }

    // MARK: - Snap

    @Test("A cable dragged from an output snaps onto the input or parameter pin under the pointer")
    func snapsToInputs() throws {
        let project = Self.project()
        let from = PinReference(moduleId: 1, side: .output, index: 0)
        let input = try #require(PinHitTest.anchor(for: PinReference(moduleId: 2, side: .input, index: 1), in: project))
        #expect(PinHitTest.target(at: CGPoint(x: input.x + 3, y: input.y - 4), from: from, in: project,
                                  pageModuleIds: Self.ids) == PinReference(moduleId: 2, side: .input, index: 1))
        let param = try #require(PinHitTest.anchor(for: PinReference(moduleId: 2, side: .param, index: 0), in: project))
        #expect(PinHitTest.target(at: CGPoint(x: param.x - 2, y: param.y + 2), from: from, in: project,
                                  pageModuleIds: Self.ids) == PinReference(moduleId: 2, side: .param, index: 0))
    }

    @Test("The snap never offers a pin the wire could not join")
    func snapRefusesWhatTheConnectionWould() throws {
        let project = Self.project()
        let from = PinReference(moduleId: 1, side: .output, index: 0)
        // Another output is not a target for a cable from an output.
        let otherOut = try #require(PinHitTest.anchor(for: PinReference(moduleId: 2, side: .output, index: 0), in: project))
        #expect(PinHitTest.target(at: otherOut, from: from, in: project, pageModuleIds: Self.ids) == nil)
        // Its own module's input is a target: a counter feeding its own reset is a self-wire, not a ring.
        let ownInputRef = PinReference(moduleId: 1, side: .input, index: 0)
        let ownInput = try #require(PinHitTest.anchor(for: ownInputRef, in: project))
        #expect(PinHitTest.target(at: ownInput, from: from, in: project, pageModuleIds: Self.ids) == ownInputRef)
        // And nothing when the pointer is in open space.
        #expect(PinHitTest.target(at: CGPoint(x: 1_000, y: 1_000), from: from, in: project, pageModuleIds: Self.ids) == nil)
        // A drag from an input looks for an output, not another input.
        let back = PinReference(moduleId: 2, side: .input, index: 0)
        #expect(PinHitTest.target(at: ownInput, from: back, in: project, pageModuleIds: Self.ids) == nil)
    }

    // MARK: - Picking

    @Test("Picking a wire is a selection of its own, and Delete removes that wire")
    func pickingAWire() throws {
        let model = AppModel()
        model.project = Self.project(wired: true)
        let key = RoutedWire.Key(outModule: 1, outPin: 0, inModule: 2, inPin: 0)

        model.selectedModuleId = 2
        model.selectedAnnotationIndex = 0
        model.selectWire(key)
        #expect(model.selectedWire == key)
        #expect(model.selectedModuleId == nil, "picking a wire ends the block selection")
        #expect(model.selectedModuleIds.isEmpty)
        #expect(model.selectedAnnotationIndex == nil, "picking a wire ends the graphic selection")

        #expect(model.deleteSelectedWire(), "Delete removes the picked wire")
        #expect(model.selectedWire == nil)
        #expect(model.project?.inConnections.isEmpty == true)
    }

    @Test("Picking a block or a graphic ends a wire's pick, so Delete acts on the last thing picked")
    func pickingSomethingElse() {
        let model = AppModel()
        model.project = Self.project(wired: true)
        let key = RoutedWire.Key(outModule: 1, outPin: 0, inModule: 2, inPin: 0)

        model.selectWire(key)
        model.selectedModuleId = 2
        #expect(model.selectedWire == nil)

        model.selectWire(key)
        model.selectedAnnotationIndex = 0
        model.selectedModuleId = nil
        #expect(model.selectedWire == nil)

        // With nothing picked, Delete finds no wire to remove and leaves the project alone.
        model.selectedWire = nil
        #expect(!model.deleteSelectedWire())
        #expect(model.project?.inConnections.count == 1)
    }
}
