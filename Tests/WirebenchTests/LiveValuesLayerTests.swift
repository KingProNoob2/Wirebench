import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// The pin rows of a block are drawn by one canvas over the sheet (`LiveValuesLayer`), so that a simulation tick changes that canvas and not
/// the cards. What makes that true is that a plain block's card is given nothing that moves when a pin does.
@Suite("Live values layer")
struct LiveValuesLayerTests {
    private func module(_ guid: UUID, id: Int = 1) -> PCCModule {
        PCCModule(id: id, guid: guid, name: "M\(id)", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                  inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))], outPins: [Pin(id: 0, value: .bool(false))])
    }

    private func snapshot(inputs: [PinValue], outputs: [PinValue], parameters: [PinValue] = []) -> BlockSnapshot {
        var s = BlockSnapshot()
        s.inValues = inputs
        s.outValues = outputs
        s.paramValues = parameters
        return s
    }

    @Test("Neither a pin nor a parameter moving changes a plain block's card: the layer draws both")
    func plainCardIgnoresPins() {
        let not = module(NotBlock.guid)
        let before = snapshot(inputs: [.bool(true), .bool(false)], outputs: [.bool(false)], parameters: [.int32(1)])
        let pinsMoved = snapshot(inputs: [.bool(true), .bool(true)], outputs: [.bool(true)], parameters: [.int32(1)])
        let paramMoved = snapshot(inputs: [.bool(true), .bool(false)], outputs: [.bool(false)], parameters: [.int32(102)])
        #expect(ModuleCardView.cardSnapshot(before, of: not) == ModuleCardView.cardSnapshot(pinsMoved, of: not),
                "a tick that moves a pin must not re-render the card")
        #expect(ModuleCardView.cardSnapshot(before, of: not) == ModuleCardView.cardSnapshot(paramMoved, of: not),
                "a parameter is a pin, drawn by the layer with the others, so a block such as Set writing one must not re-render the card")
    }

    @Test("A BoolVar or IntVar keeps its values: its control is the card's own")
    func controlsKeepValues() {
        for guid in [BoolVarBlock.guid, IntVarBlock.guid] {
            let block = module(guid)
            let off = snapshot(inputs: [], outputs: [.int32(0)])
            let on = snapshot(inputs: [], outputs: [.int32(1)])
            #expect(ModuleCardView.readsLiveValues(block))
            #expect(ModuleCardView.cardSnapshot(off, of: block) != ModuleCardView.cardSnapshot(on, of: block))
        }
    }

    @Test("Every block's rows are drawn by the layer except a Segment's, whose display sits beside its pins")
    func whoDrawsTheRows() {
        #expect(ModuleCardView.drawsRowsInLayer(module(NotBlock.guid)))
        #expect(ModuleCardView.drawsRowsInLayer(module(EightDIBlock.guid)))
        #expect(!ModuleCardView.drawsRowsInLayer(module(SegmentBlock.guid)))
        #expect(ModuleCardView.readsLiveValues(module(SegmentBlock.guid)), "its card draws the display from the values")
    }
}
