import Foundation

/// Everything a Maraflow project carries that the Dirigo-derived model has no field for.
///
/// The `.mfl` format is a flat properties document; keeping its keys verbatim is the only way to promise that an
/// import loses nothing today, including fields Wirebench does not interpret yet (tags, E-Stop rules, graphics, bus
/// ids, wire routes, ST order). Typed views can be layered over this in later stages without another format change.
public struct MaraflowExtras: Codable, Sendable, Equatable {
    /// The `.mfl` schema this project came from (`maraflow.version` when present).
    public var formatVersion: String
    /// Every key and value read from the `.mfl`, including keys this build does not understand.
    public var properties: [String: String]

    public init(formatVersion: String = "", properties: [String: String]) {
        self.formatVersion = formatVersion
        self.properties = properties
    }
}
