import Foundation
import DirigoCore

/// Builds a ready-to-use block instance for the editor.
///
/// A `.pcc` stores very little about a block: its type GUID, where it sits, and one entry per pin.
/// Crucially it does **not** store pin names — Dirigo derives the labels from the Delphi class — so
/// a newly created module only has to get the pin *counts* and their default values right, and the
/// pin layouts in `PinTemplateCatalog` are what supply those.
public enum BlockFactory {
    /// How many operands a new block gets when its input count is user-configurable.
    public static let defaultCountedInputs = 2

    /// Layouts for blocks the help does not describe.
    ///
    /// `Segment` has no pin table — only an image-only PDF — so its shape is taken from the real
    /// `.pcc` files: every one of the eight instances carries nine input pins (En + A..G + DP) and
    /// no outputs. Without this it fell back to a generic one-in/one-out block.
    static let layoutOverrides: [String: BlockPinTemplate] = {
        let segment = BlockPinTemplate(
            inputs: [PinTemplate(abbrev: "En", name: "Enabled", dataType: "Boolean", defaultValue: "1")]
                + ["A", "B", "C", "D", "E", "F", "G", "DP"].map {
                    PinTemplate(abbrev: $0, name: $0, dataType: "Boolean", defaultValue: "0")
                },
            params: [],
            outputs: []
        )
        // Construct labels carry no pins. The help gives no pin table for them and the original
        // treats them as configuration markers, so the generic one-in/one-out fallback was wrong.
        let label = BlockPinTemplate(inputs: [], params: [], outputs: [])
        var table = ["565E4F34-495E-4988-A572-E789AB4963E8": segment]
        // The help lists SystemCmd with four inputs and no parameters; every real module has `En` and `Cmd` as inputs
        // and `Par1`, `Par2` as parameters (`rulkoshaddirigo.pcc`, `zelznice.pcc`), which is what the compiler and the
        // block read.
        table["060906AA-5048-4931-BE5C-714697885084"] = BlockPinTemplate(
            inputs: [PinTemplate(abbrev: "En", name: "Enabled", dataType: "Boolean", defaultValue: "1"),
                     PinTemplate(abbrev: "Cmd", name: "Command", dataType: "Int", defaultValue: "770")],
            params: [PinTemplate(abbrev: "Par1", name: "Parametr1", dataType: "Int", defaultValue: "0"),
                     PinTemplate(abbrev: "Par2", name: "Parametr2", dataType: "Int", defaultValue: "0")],
            outputs: [PinTemplate(abbrev: "Out", name: "Output", dataType: "Int", defaultValue: "-")])
        for guid in ["4D83C589-DE5F-4FB1-9222-F5836722340B",   // Case
                     "A99FFBCE-0803-4939-AB9D-DE413F16A36F",   // Default
                     "0E92235F-6CE0-4FEC-8EB4-556846E16695",   // EndSwitch
                     "76D0013D-0CF1-406C-8366-16E299A0F7EC",   // Else
                     "506CF9FC-364B-47AF-8E3F-965F94224B06"] { // EndIf
            table[guid] = label
        }
        return table
    }()

    /// Creates a module of `guid` with the pins its type calls for.
    public static func makeModule(
        guid: UUID,
        id: Int,
        name: String,
        x: Double,
        y: Double,
        order: Int,
        threadId: Int,
        page: String
    ) -> PCCModule {
        let template = layoutOverrides[guid.uuidString.uppercased()]
            ?? PinTemplateCatalog.template(forGuid: guid)
        let inputs = makePins(from: template?.inputs ?? [], counted: template?.defaultInputCount)
        let params = makePins(from: template?.params ?? [], counted: nil)
        // A type with no recovered pin layout still gets a connected-looking block rather than one
        // with no pins at all, which would be unselectable and un-wireable.
        let outputs = template == nil
            ? makePins(from: [PinTemplate(abbrev: "Y", name: "Y", dataType: "Boolean",
                                          defaultValue: "-")], counted: nil, isOutput: true)
            : makePins(from: template!.outputs, counted: nil, isOutput: true)

        return PCCModule(
            id: id,
            guid: guid,
            name: name,
            x: x,
            y: y,
            order: order,
            threadId: threadId,
            page: page,
            inputCount: template?.defaultInputCount,
            inPins: template == nil
                ? makePins(from: [PinTemplate(abbrev: "En", name: "Enabled", dataType: "Boolean",
                                              defaultValue: "1")], counted: nil)
                : inputs,
            paramPins: params,
            outPins: outputs
        )
    }

    /// Builds the pin list, expanding a configurable input count.
    ///
    /// The help documents a configurable block as its first two operands *plus* a general
    /// `X(N-1)` row, so the general row replaces the operands rather than adding to them: `And`
    /// with N = 2 becomes `En, X0, X1`, matching what Dirigo itself writes.
    static func makePins(
        from specs: [PinTemplate],
        counted: Int?,
        isOutput: Bool = false
    ) -> [Pin] {
        var pins: [Pin] = []

        func append(_ spec: PinTemplate, abbrev: String) {
            pins.append(Pin(
                id: pins.count,
                value: PinValue.parse(spec.defaultValue),
                inverted: false,
                rights: isOutput ? 2 : 0,
                name: nil,
                format: nil
            ))
            _ = abbrev
        }

        let placeholder = specs.first { $0.isCountedInput }
        let count = max(1, counted ?? defaultCountedInputs)
        let prefix = placeholder.map { String($0.abbrev.prefix(while: { $0 != "(" })) } ?? "X"

        for spec in specs where !spec.isCountedInput {
            // Operands shown explicitly (X0, X1) give way to the generated run.
            if placeholder != nil, spec.abbrev.hasPrefix(prefix), spec.abbrev.dropFirst(prefix.count).allSatisfy(\.isNumber) {
                continue
            }
            append(spec, abbrev: spec.abbrev)
        }
        if placeholder != nil {
            for index in 0..<count {
                pins.append(Pin(
                    id: pins.count,
                    value: .bool(false),
                    inverted: false,
                    rights: 0,
                    name: nil,
                    format: nil
                ))
                _ = index
            }
        }
        return pins
    }

    /// Dirigo names instances `<Type><number>`. Picks the next free one.
    public static func suggestedName(for guid: UUID, existing: [PCCModule]) -> String {
        let base = BlockTypeCatalog.info(forGuid: guid)?.blockName ?? "Block"
        let taken = existing.map(\.name)
        if !taken.contains(base) { return base }
        var index = 1
        while taken.contains("\(base)\(index)") { index += 1 }
        return "\(base)\(index)"
    }

    /// Next free module ID on the project.
    public static func nextId(in project: PCCProject) -> Int {
        (project.modules.map(\.id).max() ?? 0) + 1
    }

    /// Next execution order on a page. Dirigo numbers in tens.
    public static func nextOrder(in project: PCCProject, page: String) -> Int {
        let orders = project.modules.filter { $0.page == page }.map(\.order)
        return (orders.max() ?? 0) + 10
    }
}
