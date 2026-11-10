import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine

/// What the inspector shows for one block, as plain values: what it is, its pins with live values and how each can be
/// edited, and where it runs. Shared by every frontend; the SwiftUI inspector builds the same rows from the model.
public struct InspectorSnapshot: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public var label: String
        public var value: String
        public var high: Bool
        /// `toggle` (click flips a boolean input), `int` (a number can be typed), or `text` (shown only).
        public var kind: String
    }

    public var id: Int
    public var name: String
    public var type: String
    public var category: String
    public var summary: String
    public var className: String
    public var simulated: Bool
    public var order: Int
    public var thread: Int
    public var page: String
    public var x: Double
    public var y: Double
    public var inputs: [Row]
    public var outputs: [Row]
    public var params: [Row]

    @MainActor
    public static func make(of model: AppModel, moduleId: Int) -> InspectorSnapshot? {
        guard let module = model.module(id: moduleId) else { return nil }
        let info = BlockTypeCatalog.info(forGuid: module.guid)
        let node = model.getNode(id: moduleId)

        func kind(of value: PinValue) -> String {
            switch value {
            case .bool: return "toggle"
            case .int16, .int32, .int64: return "int"
            default: return "text"
            }
        }

        let inputs = module.inPins.indices.map { i -> Row in
            let value = node?.block.inPins[safe: i] ?? module.inPins[i].value
            return Row(label: ModulePinCatalog.inputPinFullName(for: module, index: i),
                       value: PinDisplay.inputText(value, index: i, guid: module.guid), high: value.asBool, kind: kind(of: value))
        }
        let outputs = module.outPins.indices.map { i -> Row in
            let value = node?.block.outPins[safe: i] ?? .bool(false)
            // An `IntVar`'s output is the variable itself, so it can be typed over.
            return Row(label: ModulePinCatalog.outputPinFullName(for: module, index: i),
                       value: value.description, high: value.asBool,
                       kind: BlockRole.isIntVariable(module) ? "int" : "text")
        }
        let params = module.paramPins.indices.map { i -> Row in
            let value = node?.block.paramPins[safe: i] ?? module.paramPins[i].value
            return Row(label: ModulePinCatalog.paramPinFullName(for: module, index: i),
                       value: value.description, high: false, kind: "int")
        }
        return InspectorSnapshot(
            id: module.id, name: module.name, type: info?.blockName ?? "", category: info?.category ?? "",
            summary: info?.summary ?? "", className: info?.delphiClass ?? "",
            simulated: CxxSimulationCore.kind(forGUID: module.guid) != nil,
            order: module.order, thread: module.threadId, page: module.page, x: module.x, y: module.y,
            inputs: inputs, outputs: outputs, params: params)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
