import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// The palette sees merged categories and distinguishable Maraflow rows.
@Suite("Maraflow palette")
struct MaraflowPaletteTests {
    @Test("Maraflow categories merge into the Dirigo groups")
    func categoriesMerge() {
        let categories = BlockPaletteSearch.categories()
        let shown = categories.map { BlockPaletteSearch.displayName(for: $0) }
        #expect(shown.filter { $0 == "Communication" }.count == 1)
        #expect(!shown.contains { $0.hasPrefix("Communication/") })
        #expect(shown.contains("Ladder"))
        #expect(!shown.contains { $0.contains("Ladder (LD)/") })
        #expect(shown.filter { $0 == "Comparators" }.count == 1)
        for info in MaraflowCatalog.infos {
            #expect(!info.category.contains("/") || info.category == "I/O", "palette category still has a path: \(info.category)")
            #expect(info.summary.contains("Maraflow"))
        }
    }

    @Test("A native block whose name collides with Dirigo is marked")
    func collidingNames() {
        let nativeAnd = MaraflowCatalog.byId["Bool.And"]!
        let nativeInfo = BlockTypeCatalog.info(forGuid: nativeAnd.guid)!
        #expect(BlockPaletteSearch.displayBlockName(for: nativeInfo) == "And (Maraflow)")
        let dirigoAnd = BlockTypeCatalog.info(forBlockName: "And")!
        #expect(BlockPaletteSearch.displayBlockName(for: dirigoAnd) == "And")
        let tcp = BlockTypeCatalog.info(forGuid: MaraflowCatalog.byId["Comm.ModbusTCP.MbTcpRead"]!.guid)!
        #expect(BlockPaletteSearch.displayBlockName(for: tcp) == "MbTcpRead")
        #expect(tcp.category == "Communication")
    }
}
