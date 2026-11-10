import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchEngine

/// Every block kind the C++ core claims, run against the Swift engine on random inputs.
///
/// `CxxSimulationTests` compares the engines on hand-built fixtures and on the corpus, which only reaches the
/// pins and values those projects happen to use. This is the check a port of ~130 block types needs: for each
/// GUID `CxxSimulationCore.kind(forGUID:)` maps, build the module exactly as the app does (`BlockFactory`), feed
/// both engines the same seeded random inputs and parameters for a few hundred steps, and require every pin to
/// agree after every step. A kind counts as ported when it passes here, not when it has a `case`.
/// Serialized: the Swift engine keeps its array data area in a process-wide singleton (`IntArrayStore.shared`),
/// so two cases running at once could read each other's arrays. The core's arrays belong to each simulation.
@Suite("C++ core: every ported block agrees with Swift on random inputs", .serialized)
struct CxxBlockFuzzTests {
    static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// A small deterministic generator, so a failure names a step that can be replayed.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    }

    /// A random value of the same kind as `template`, biased towards the small numbers branches care about.
    static func randomValue(like template: PinValue, isEnable: Bool, rng: inout SplitMix64) -> PinValue {
        switch template {
        case .bool:
            return .bool(isEnable ? rng.chance(0.85) : rng.chance(0.5))
        case .float:
            return .float(Float(rng.int(-400...400)) / 20)
        case .int16:
            return .int16(Int16(rng.chance(0.9) ? rng.int(-4...20) : rng.int(-32768...32767)))
        case .int64:
            return .int64(Int64(rng.chance(0.9) ? rng.int(-4...20) : rng.int(-2_000_000_000...2_000_000_000)))
        case .int32, .undefined:
            // Mostly small; sometimes a year, so date blocks see values inside their documented range too.
            if rng.chance(0.85) { return .int32(Int32(rng.int(-4...20))) }
            if rng.chance(0.4) { return .int32(Int32(rng.int(1975...2200))) }
            return .int32(Int32(rng.int(-2_000_000_000...2_000_000_000)))
        }
    }

    /// Every GUID the registry builds and the core claims.
    static var portedGuids: [UUID] {
        BlockRegistry.shared.registeredGuids
            .filter { CxxSimulationCore.kind(forGUID: $0) != nil }
            .sorted { $0.uuidString < $1.uuidString }
    }

    static func label(_ guid: UUID) -> String {
        BlockTypeCatalog.info(forGuid: guid)?.blockName ?? guid.uuidString
    }

    @Test("Ported block agrees with Swift on random inputs", arguments: portedGuids)
    func blockAgrees(guid: UUID) {
        let name = Self.label(guid)
        let module = BlockFactory.makeModule(guid: guid, id: 1, name: "\(name)1", x: 0, y: 0,
                                             order: 10, threadId: 1, page: "main")
        var project = PCCProject(name: name)
        project.pages = [ProjectPage(caption: "main")]
        project.appOptions.cycleDelay = 10
        project.modules = [module]

        IntArrayStore.shared.reset()
        // The Swift reference is the block's own class, run as the Swift engine ran an unwired module.
        let swift = BlockOracle(module: module, cycleDelayMs: 10, now: Self.fixedNow)
        let cxx = CxxSimulationCore(project: project, profileScheduling: false)
        let node = swift

        // Seeded from the GUID's bytes, not `hashValue`, which is randomised per process: a failure has to
        // reproduce on the next run.
        let seed = withUnsafeBytes(of: guid.uuid) { $0.load(fromByteOffset: 0, as: UInt64.self) }
        var rng = SplitMix64(state: seed | 1)
        let inTemplates = node.block.inPins
        let paramTemplates = node.block.paramPins
        var mismatches = 0

        for step in 0..<300 {
            // Change a few pins per step rather than all of them, so edges and held states get exercised.
            for pin in inTemplates.indices where step == 0 || rng.chance(0.3) {
                var value = Self.randomValue(like: inTemplates[pin], isEnable: pin == 0, rng: &rng)
                // A Dirigo date is days since 1980 and ends in 2190 (~77,000 days). Outside a sane window
                // Foundation's `Calendar` stops being the calendar the core implements: hundreds of millions of
                // days overflow it, years before 1 AD come back as positive BC-era years, and before October
                // 1582 its "gregorian" calendar is Julian. So the comparison is held to 1600 ... ~4700.
                if name == "DecodeDate", pin == 1 {
                    value = .int32(Int32(clamping: max(-138_000, min(1_000_000, value.asInt))))
                }
                node.block.inPins[pin] = value
                cxx.setIn(moduleId: 1, pin: pin, value: value)
            }
            for pin in paramTemplates.indices where step == 0 || rng.chance(0.1) {
                let value = Self.randomValue(like: paramTemplates[pin], isEnable: false, rng: &rng)
                node.block.paramPins[pin] = value
                cxx.setParam(moduleId: 1, pin: pin, value: value)
            }

            swift.step()
            cxx.step(deltaMs: 10, now: Self.fixedNow)

            for pin in node.block.outPins.indices {
                let theirs = cxx.outValue(moduleId: 1, pin: pin)?.description ?? "-"
                let ours = node.block.outPins[pin].description
                if theirs != ours {
                    mismatches += 1
                    if mismatches <= 5 {
                        Issue.record("\(name): step \(step) out[\(pin)] cxx \(theirs) vs swift \(ours); ins \(node.block.inPins) params \(node.block.paramPins)")
                    }
                }
            }
            for pin in node.block.inPins.indices {
                let theirs = cxx.inValue(moduleId: 1, pin: pin)?.description ?? "-"
                let ours = node.block.inPins[pin].description
                if theirs != ours {
                    mismatches += 1
                    if mismatches <= 5 {
                        Issue.record("\(name): step \(step) in[\(pin)] cxx \(theirs) vs swift \(ours)")
                    }
                }
            }
            if mismatches > 5 { break }
        }
    }

    /// Not a check: how far the port reaches, printed so progress is visible in the test log.
    @Test("Coverage of the registered block types")
    func coverage() {
        let registered = BlockRegistry.shared.registeredGuids
        let ported = registered.filter { CxxSimulationCore.kind(forGUID: $0) != nil }
        let missing = registered.subtracting(ported).map(Self.label).sorted()
        print("C++ core coverage: \(ported.count) of \(registered.count) registered block types")
        print("Not yet ported: \(missing.joined(separator: ", "))")
    }
}
