import Foundation

/// Builds the sheet's graphic objects (annotations) in Dirigo's own encoding.
///
/// The shapes here are copied from a real project — `autoplexer.pcc` — because nothing documents
/// them: the help has no graphics section at all. A text object in particular carries `FONT`
/// attributes this app does not model (`UNDERLINE`, `STRIKE_OUT`, `CHARSET`), so the `FONT` subtree
/// is built verbatim. Synthesising it from the typed fields instead would hand Dirigo a `FONT`
/// element it has never written, and the round-trip tests would no longer describe real files.
public enum PCCGraphicBuilder {

    /// The graphic types observed in real projects.
    public enum Kind: Int, Sendable {
        /// A line: one `NODE` per point, plus `PEN`/`BRUSH` and an optional `INPUT` reference.
        case line = 2
        /// A text object: a single `NODE` for its position, a `TEXT` attribute, and a `FONT`.
        case text = 4
    }

    /// Dirigo's default text appearance, taken verbatim from `autoplexer.pcc`.
    public static let fontName = "Tahoma"
    public static let fontSize = 8
    public static let fontColor = "$FF000008"
    public static let fontCharset = 1

    /// A text object, exactly as Dirigo writes one.
    ///
    /// - Parameter point: where the text starts. Dirigo stores a single node for it, and that node is
    ///   the only position information there is.
    public static func text(_ string: String,
                            at point: RoutePoint,
                            page: String,
                            name: String = fontName,
                            size: Int = fontSize,
                            color: String = fontColor) -> ProjectGraphic {
        let nodes = RawXMLNode(name: "NODES", children: [
            RawXMLNode(name: "NODE", attributes: AttributeBag([("X", number(point.x)),
                                                              ("Y", number(point.y))])),
        ])
        let font = RawXMLNode(name: "FONT", attributes: AttributeBag([
            ("NAME", name),
            ("BOLD", "False"),
            ("ITALIC", "False"),
            ("UNDERLINE", "False"),
            ("STRIKE_OUT", "False"),
            ("SIZE", String(size)),
            ("COLOR", color),
            ("CHARSET", String(fontCharset)),
        ]))

        return ProjectGraphic(type: Kind.text.rawValue,
                              page: page,
                              text: string,
                              nodes: [point],
                              fontName: name,
                              fontSize: size,
                              fontBold: false,
                              fontItalic: false,
                              fontColor: color,
                              rawChildren: [nodes, font])
    }

    /// Coordinates are written as integers when they are whole, the way Dirigo writes them.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
