import Testing
import Foundation
import WirebenchCore
@testable import WirebenchModel

/// Dirigo draws a block's parameters (`PV`, `Max`, `Min`, `St` under `AdvCounter`'s inputs) as pins in the left column, and a wire can end on one;
/// the file keeps those in `PARAM_CONNECTIONS`.
@Suite("Parameter pins")
@MainActor
struct ParameterPinTests {
    private func model() throws -> AppModel {
        let model = AppModel()
        model.loadProject(url: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kostka-1.pcc"))
        model.selectedPage = "List 1"
        return model
    }

    @Test("A wire can end on a parameter pin: it is kept, drawn to that pin, found by the pointer, and removable")
    func wireToAParameter() throws {
        let model = try model()
        let project = try #require(model.project)
        let counter = try #require(project.modules.first { $0.name == "AdvCounter1" })     // PV, Max, Min, St
        let source = try #require(project.modules.first { $0.name == "PulseGen1" })
        let max = PinReference(moduleId: counter.id, side: .param, index: 1)
        let before = project.paramConnections.count

        #expect(model.connectPins(from: PinReference(moduleId: source.id, side: .output, index: 0), to: max))
        let wired = try #require(model.project)
        #expect(wired.paramConnections.count == before + 1 && wired.paramConnections.last?.isParam == true)
        #expect(wired.inConnections.count == project.inConnections.count, "a parameter wire is not an input wire")

        // The pin is a row after the inputs, and that is where the wire ends.
        let point = CardGeometry.paramPinPoint(for: counter, pinIndex: 1)
        #expect(point.y == CardGeometry.inPinPoint(for: counter, pinIndex: counter.inPins.count + 1).y)
        #expect(PinHitTest.pin(at: point, in: wired, pageModuleIds: Set(wired.modules.map(\.id))) == max)
        let scene = SceneSnapshot.make(of: model, layout: WireLayout(), dragOffsets: [:], graphicDrag: [:], quit: false)
        let wire = try #require(scene.wires.first { $0.inModule == counter.id && $0.inParam && $0.inPin == 1 })
        let end = try #require(wire.points.last)
        #expect(abs(end[0] - Double(point.x)) < 0.5 && abs(end[1] - Double(point.y)) < 0.5, "ends at the parameter pin, not an input: \(end) \(point)")
        #expect(scene.modules.first { $0.id == counter.id }?.paramPins[1].connected == true)

        // Dropped on an output, or between two inputs, it is not a wire; removing it takes the connection away.
        #expect(!model.connectPins(from: max, to: PinReference(moduleId: counter.id, side: .input, index: 0)))
        #expect(model.disconnectPin(max))
        #expect(model.project?.paramConnections.count == before)
    }

    @Test("The rows of a block count its parameters, so its card is as tall as they need")
    func parametersTakeRows() throws {
        let project = try #require(try model().project)
        let counter = try #require(project.modules.first { $0.name == "AdvCounter1" })
        let rows = max(counter.inPins.count + counter.paramPins.count, counter.outPins.count)
        #expect(CardGeometry.cardHeight(for: counter) == CardGeometry.gridAligned(CardGeometry.Metrics.headerHeight + CGFloat(rows) * CardGeometry.pinPitch + 8))
    }
}
