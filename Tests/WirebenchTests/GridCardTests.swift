import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
@testable import WirebenchModel
@testable import WirebenchSource

/// A card is a whole number of grid cells, so its edges sit on the sheet's dots.
@Suite("Grid-aligned cards")
struct GridCardTests {
    private let grid = CGFloat(GridSnap.step)

    private func module(_ name: String, id: Int = 1) throws -> PCCModule {
        let guid = try #require(BlockTypeCatalog.info(forBlockName: name)?.guid)
        return BlockFactory.makeModule(guid: guid, id: id, name: "\(name)\(id)", x: 0, y: 0,
                                       order: 10, threadId: 1, page: "main")
    }

    @Test("Card widths and heights are multiples of the grid step")
    func sizesFitGrid() throws {
        for name in ["And", "BoolVar", "Segment", "IAdd", "AdvCounter", "8xDI", "FMul"] {
            let block = try module(name)
            let width = CardGeometry.cardWidth(for: block)
            let height = CardGeometry.cardHeight(for: block)
            #expect(width.truncatingRemainder(dividingBy: grid) == 0, "\(name) width \(width)")
            #expect(height.truncatingRemainder(dividingBy: grid) == 0, "\(name) height \(height)")
        }
    }

    @Test("The Dirigo export extent stays the measured size")
    func exportIsNotPadded() throws {
        let and = try module("And")
        #expect(CardGeometry.dirigoExtent(for: and).width == 110)
    }

    @Test("Compiled placements land on grid intersections")
    func compiledPlacementFitsGrid() throws {
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR a AT %IX0 : BOOL; lamp AT %QX0 : BOOL; n : INT := 0; END_VAR
            n := n + 1;
            lamp := n > 3;
        END_PROGRAM
        """)
        for block in compiled.project.modules {
            #expect(block.x.truncatingRemainder(dividingBy: Double(GridSnap.step)) == 0, "x \(block.x)")
            #expect(block.y.truncatingRemainder(dividingBy: Double(GridSnap.step)) == 0, "y \(block.y)")
        }
    }
}
