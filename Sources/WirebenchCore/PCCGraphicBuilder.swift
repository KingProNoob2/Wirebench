import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Builds the sheet's graphic objects (annotations) in Dirigo's own encoding.
///
/// The shapes here are copied from a real project — `autoplexer.pcc` — because nothing documents
/// them: the help has no graphics section at all. A text object in particular carries `FONT`
/// attributes this app does not model (`UNDERLINE`, `STRIKE_OUT`, `CHARSET`), so the `FONT` subtree
/// is built verbatim. Synthesising it from the typed fields instead would hand Dirigo a `FONT`
/// element it has never written, and the round-trip tests would no longer describe real files.
public enum PCCGraphicBuilder {

    /// Graphic types, as written in a `GRAPHICS` element's `TYPE` attribute.
    ///
    /// These are the ordinals of the original's `TPCCProjectGraphicsType`, read out of the Delphi enum
    /// RTTI in `Dirigo_unpacked.exe` (VA `0x4430EC`, `MinValue=0`, `MaxValue=5`): `pgtNone`,
    /// `pgtLine`, `pgtRectangle`, `pgtEllipse`, `pgtText`, `pgtButton`. Three things agree with that.
    /// The five graphic subclasses — `TPCCLine`, `TPCCRectangle`, `TPCCEllipse`, `TPCCText`,
    /// `TPCCButton` — each hold an `FGraphicsType` of this enum and are declared in the same order. The
    /// drawing tools (`AArrow`, `ALine`, `ARectangle`, `AEllipse`, `AText`, `AButton`) line up once
    /// Arrow is `pgtNone`, the select tool, which creates no object and so appears in no file. And the
    /// corpus bears it out: the one `TYPE="1"` object carries `PEN` and no `BRUSH`, a line having no
    /// fill; the `TYPE="2"` objects span aspect ratios 0.4 to 5.0, while every non-degenerate
    /// `TYPE="3"` object is near-square, which is an ellipse's box.
    ///
    /// `pgtNone` and `pgtButton` are left out because nothing reads or writes them: no project on this
    /// machine contains a `TYPE="0"` or `TYPE="5"` object. A `TYPE` with no case here decodes to `nil`
    /// from `objectKind`, which is the honest answer rather than a shape drawn from a guess.
    public enum Kind: Int, Sendable {
        /// A line: two `NODES` and a `PEN`. Real ones carry no `BRUSH`, a line having no fill.
        case line = 1
        /// A rectangle: two corner `NODES` and `PEN`/`BRUSH`.
        case rectangle = 2
        /// An ellipse — Dirigo's tool draws a circle while its box is square.
        case ellipse = 3
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

    /// Pen and brush as real projects write them (`had+1block.pcc`): a solid black line, one point
    /// wide, filled white.
    public static let penColor = "$000000"
    public static let penMode = 4
    public static let penStyle = 0
    public static let penWidth = 1
    public static let brushColor = "$FFFFFF"
    /// `1` is Delphi's `bsClear`: an outline with nothing inside it. Dirigo's own files use `0`
    /// (`bsSolid`) with white, which is invisible on its white sheet but would paint a white panel
    /// over this app's canvas and anything drawn under it, so a shape added here asks for no fill.
    public static let brushStyle = 1

    /// A rectangle or ellipse, written as the two corner nodes and the `PEN`/`BRUSH` that draw it.
    ///
    /// Built from the typed fields rather than a verbatim subtree: this app has never seen one of
    /// these in a file, so there is no real markup to copy — and the serializer emits the same
    /// `NODES`/`PEN`/`BRUSH` children either way.
    public static func shape(_ kind: Kind,
                             in box: GraphicBox,
                             page: String,
                             penColor: String = PCCGraphicBuilder.penColor,
                             penWidth: Int = PCCGraphicBuilder.penWidth,
                             brushColor: String = PCCGraphicBuilder.brushColor,
                             brushStyle: Int = PCCGraphicBuilder.brushStyle) -> ProjectGraphic {
        ProjectGraphic(type: kind.rawValue,
                       page: page,
                       nodes: box.corners,
                       penColor: penColor,
                       penMode: penMode,
                       penStyle: penStyle,
                       penWidth: penWidth,
                       brushColor: brushColor,
                       brushStyle: brushStyle)
    }

    /// Coordinates are written as integers when they are whole, the way Dirigo writes them.
    public static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
