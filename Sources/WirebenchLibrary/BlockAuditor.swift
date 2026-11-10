import Foundation
import WirebenchCore

/// The outcome of exercising one block type.
public struct BlockAuditResult: Sendable {
    public let name: String
    public let guid: UUID
    public let category: String
    /// The concrete Swift type the registry produced.
    public let resolvedType: String
    /// True when the registry had no implementation and returned the inert placeholder.
    public let isPlaceholder: Bool
    public let inPins: Int
    public let paramPins: Int
    public let outPins: Int
    /// Pin counts the help documents, when a layout was recovered for this type.
    public let documentedInPins: Int?
    public let documentedParamPins: Int?
    public let documentedOutPins: Int?
    public let notes: [String]

    public var pinCountMatchesDocumentation: Bool {
        guard let documentedInPins, let documentedParamPins, let documentedOutPins else { return true }
        return inPins == documentedInPins && paramPins == documentedParamPins
            && outPins == documentedOutPins
    }
}

public enum BlockAuditor {
    /// Number of ticks each block is exercised for.
    public static let ticks = 5

    /// Builds, instantiates and runs **every** block type in the catalog.
    ///
    /// This is the broad sweep: it proves a type can be created from a fresh module, that the
    /// registry resolves it, that its pins are non-degenerate, and that stepping it does not
    /// produce a non-finite value. It cannot prove a block *computes the right thing* — that needs
    /// the documented truth tables, which the per-block tests cover.
    public static func auditAll() -> [BlockAuditResult] {
        BlockTypeCatalog.all.map { audit(guid: $0.guid) }
    }

    public static func audit(guid: UUID) -> BlockAuditResult {
        let info = BlockTypeCatalog.info(forGuid: guid)
        let name = info?.blockName ?? "?"
        let category = info?.category ?? ""

        let module = BlockFactory.makeModule(
            guid: guid, id: 1, name: "Audit1", x: 0, y: 0,
            order: 10, threadId: 1, page: "main"
        )
        let block = BlockRegistry.shared.create(for: module)
        let isPlaceholder = block is UnresolvedBlock

        var notes: [String] = []
        if block.inPins.isEmpty && block.outPins.isEmpty {
            notes.append("no pins at all")
        }

        // Exercise it. A block that throws a non-finite value on default inputs is broken
        // regardless of what the help says it should do.
        let sample = SampleContext()
        for tick in 0..<ticks {
            block.process(sample: sample)
            for (index, value) in block.outPins.enumerated() where !value.isFinite {
                notes.append("output \(index) non-finite at tick \(tick)")
            }
            for (index, value) in block.paramPins.enumerated() where !value.isFinite {
                notes.append("param \(index) non-finite at tick \(tick)")
            }
        }

        let template = PinTemplateCatalog.template(forGuid: guid)
        let documented = template.map { t -> (Int, Int, Int) in
            let inputs = t.inputs.reduce(0) { total, spec in
                total + (spec.isCountedInput ? (t.defaultInputCount ?? PinTemplateCatalog.defaultCountedInputs) : 1)
            }
            // The documented layout lists the counted operands *and* a general row; the general row
            // replaces them, so a type with a counted input has one fewer explicit operand.
            let explicitOperands = t.inputs.filter { spec in
                guard let counted = t.inputs.first(where: \.isCountedInput) else { return false }
                let prefix = String(counted.abbrev.prefix(while: { $0 != "(" }))
                return spec.abbrev.hasPrefix(prefix) && spec.abbrev.dropFirst(prefix.count).allSatisfy(\.isNumber)
            }.count
            let adjusted = inputs - (t.defaultInputCount == nil ? 0 : explicitOperands)
            return (adjusted, t.params.count, t.outputs.count)
        }

        return BlockAuditResult(
            name: name,
            guid: guid,
            category: category,
            resolvedType: String(describing: type(of: block)),
            isPlaceholder: isPlaceholder,
            inPins: block.inPins.count,
            paramPins: block.paramPins.count,
            outPins: block.outPins.count,
            documentedInPins: documented?.0,
            documentedParamPins: documented?.1,
            documentedOutPins: documented?.2,
            notes: notes
        )
    }

    /// A plain-text report, for the CLI and for pasting into a review.
    public static func report(_ results: [BlockAuditResult]) -> String {
        let implemented = results.filter { !$0.isPlaceholder }
        let placeholders = results.filter(\.isPlaceholder)
        let mismatched = results.filter { !$0.isPlaceholder && !$0.pinCountMatchesDocumentation }
        let broken = results.filter { !$0.notes.isEmpty }

        var out: [String] = []
        out.append("Block audit — \(results.count) types in the catalog")
        out.append("  implemented : \(implemented.count)")
        out.append("  placeholder : \(placeholders.count)")
        out.append("  pin mismatch: \(mismatched.count)")
        out.append("  misbehaving : \(broken.count)")
        out.append("")

        if !mismatched.isEmpty {
            out.append("PIN COUNTS DIFFER FROM THE HELP")
            for r in mismatched.sorted(by: { $0.name < $1.name }) {
                out.append(String(format: "  %-18@ in %d/%d  param %d/%d  out %d/%d",
                                  r.name as NSString,
                                  r.inPins, r.documentedInPins ?? -1,
                                  r.paramPins, r.documentedParamPins ?? -1,
                                  r.outPins, r.documentedOutPins ?? -1))
            }
            out.append("")
        }

        if !broken.isEmpty {
            out.append("MISBEHAVING")
            for r in broken.sorted(by: { $0.name < $1.name }) {
                out.append("  \(r.name): \(r.notes.joined(separator: "; "))")
            }
            out.append("")
        }

        out.append("NOT IMPLEMENTED (\(placeholders.count))")
        let byCategory = Dictionary(grouping: placeholders, by: \.category)
        for category in byCategory.keys.sorted() {
            let names = byCategory[category]!.map(\.name).sorted()
            out.append("  \(category.isEmpty ? "(uncategorised)" : category): \(names.joined(separator: ", "))")
        }
        return out.joined(separator: "\n")
    }
}

extension PinValue {
    /// False for a NaN or infinite float. Integer and boolean pins are always finite.
    public var isFinite: Bool {
        if case .float(let value) = self { return value.isFinite }
        return true
    }
}
