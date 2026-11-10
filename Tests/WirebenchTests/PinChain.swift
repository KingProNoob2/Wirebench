import Foundation
@testable import WirebenchCore

/// A recorded run of a project, small enough to keep in source.
///
/// Every step's pins — each of the project's own modules, by id, inputs then outputs, as `PinValue.description` —
/// are hashed into a running FNV-1a chain, and the chain is kept at a few checkpoints. Two engines whose chains
/// agree at a checkpoint agreed on every pin of every step up to it; one that disagrees is narrowed to the
/// window since the last checkpoint that held.
///
/// This is what replaced comparing against the Swift engine once the Swift engine was deleted: the recordings
/// in `CorpusRecordings` were taken from it while the two engines agreed pin for pin on every project.
struct PinChain {
    static let steps = 200
    static let checkpoints = [49, 99, 149, 199]

    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private(set) var recorded: [UInt64] = []

    private mutating func mix(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }

    /// Folds in one step's pins and records the chain when `step` is a checkpoint.
    mutating func add(step: Int, modules: [PCCModule], inPins: (Int) -> [PinValue], outPins: (Int) -> [PinValue]) {
        for module in modules.sorted(by: { $0.id < $1.id }) {
            let line = "\(module.id):" + inPins(module.id).map(\.description).joined(separator: ",")
                + "|" + outPins(module.id).map(\.description).joined(separator: ",") + ";"
            for byte in line.utf8 { mix(byte) }
        }
        if Self.checkpoints.contains(step) { recorded.append(value) }
    }
}
