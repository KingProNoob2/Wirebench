import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A verbatim, in-memory copy of an XML element.
///
/// The `.pcc` reader models the parts of the file Dirigo's own UI manipulates; everything else
/// it keeps as a `RawXMLNode` so that saving a project can never silently drop data. This is
/// what makes `PCCSerializer` lossless: unknown sections, unknown children and unknown
/// attributes are written back exactly as they were read.
public struct RawXMLNode: Sendable, Equatable, Codable {
    public var name: String
    public var attributes: AttributeBag
    public var children: [RawXMLNode]

    public init(name: String, attributes: AttributeBag = [:], children: [RawXMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    /// Captures an element and its whole subtree.
    public init(_ element: XMLElement) {
        self.name = element.name ?? ""
        self.attributes = XMLAttributes.bag(of: element)
        var kids: [RawXMLNode] = []
        for child in element.children ?? [] {
            if let childElement = child as? XMLElement {
                kids.append(RawXMLNode(childElement))
            }
        }
        self.children = kids
    }


}

/// Names of the `.pcc` elements the object model understands. Everything else is preserved as
/// a `RawXMLNode`.
public enum PCCElement {
    public static let root = "PCC_PROJECT"
    public static let communication = "COMMUNICATION"
    public static let appOptions = "APP_OPTIONS"
    public static let simOptions = "SIM_OPTIONS"
    public static let pages = "PAGES"
    public static let modules = "MODULES"
    public static let connections = "CONNECTIONS"
    public static let projectGraphics = "PROJECT_GRAPHICS"
    /// Not one of Dirigo's: this editor's own section, the `SystemCmd` blocks a project holds as its PLC configuration. The original ignores
    /// it, and *Export Legacy .PCC* writes them back as blocks (see `PLCConfiguration`).
    public static let plcConfiguration = "PLC_CONFIGURATION"

    /// The order Dirigo itself writes sections in when a project has none of its own.
    public static let defaultSectionOrder = [
        communication, appOptions, simOptions, pages, "CONSTANTS", modules,
        connections, projectGraphics,
    ]

    public static let modelledSections: Set<String> = [
        communication, appOptions, simOptions, pages, modules, connections, projectGraphics, plcConfiguration,
    ]
}
