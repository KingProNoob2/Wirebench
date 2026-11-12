import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Writes a `PCCProject` back out in exactly the shape Dirigo writes.
///
/// The writer has two jobs:
///
/// 1. **Never lose data.** Every element carries the attributes it was read with
///    (`AttributeBag`, order preserved) and, where the model does not understand a subtree, the
///    subtree itself (`RawXMLNode`). Modelled values are merged *into* those raw attributes, so
///    an unmodified project round-trips byte for byte, and a project the app only partially
///    understands still keeps everything else.
/// 2. **Match Dirigo's formatting.** Two spaces per nesting level, one element per line,
///    childless elements self-closed, no trailing newline, and control characters written as
///    numeric character references (`&#9;`, `&#xA;`) exactly as the original does.
public final class PCCSerializer: @unchecked Sendable {
    public init() {}

    public func serialize(project: PCCProject) -> String {
        var out = ""
        selfCloseSpace = project.selfClosingSpace ? " />" : "/>"
        render(section: rootElement(for: project), level: 0, into: &out)
        return out
    }

    /// `<TAG .../>` in current Dirigo builds, `<TAG ... />` in older ones. Set from the project
    /// being written so a re-save matches the file it came from.
    private var selfCloseSpace = "/>"

    // MARK: - Element tree

    private indirect enum XMLOut {
        case leaf(name: String, attrs: AttributeBag)
        case node(name: String, attrs: AttributeBag, children: [XMLOut])
    }

    // MARK: - Root

    private func rootElement(for project: PCCProject) -> XMLOut {
        var a = Attrs(project.rawAttributes)
        a.str("APPLICATION", project.application)
        a.str("APPLICATION_VERSION", project.applicationVersion)
        a.str("NAME", project.name)
        a.str("DESCRIPTION", project.description)
        a.str("AUTHOR", project.author)
        a.str("VERSION", project.version)
        a.str("PROFILE", project.profile)
        a.int("THREADINDEX", project.threadIndex)
        a.bool("OLD_EXPORT_MODE", project.oldExportMode)
        a.int("PAGESIZE", project.pageSize)
        // These three are omitted entirely when empty. Dirigo writes them only when the project
        // actually carries a path, and emitting `APPLICATION_PATH=""` and friends added 57 bytes to
        // every such file — which broke the byte-identical round-trip that the rest of this
        // serializer preserves.
        if !project.applicationPath.isEmpty { a.str("APPLICATION_PATH", project.applicationPath) }
        if !project.projectPath.isEmpty { a.str("PROJECT_PATH", project.projectPath) }
        if !project.origProjectPath.isEmpty { a.str("ORIG_PROJECT_PATH", project.origProjectPath) }

        var children: [XMLOut] = []
        for name in emissionOrder(for: project) {
            switch name {
            case PCCElement.communication:
                children.append(communicationElement(project.communication))
            case PCCElement.appOptions:
                children.append(appOptionsElement(project.appOptions))
            case PCCElement.simOptions:
                children.append(simOptionsElement(project.simOptions))
            case PCCElement.pages:
                children.append(pagesElement(project.pages))
            case PCCElement.modules:
                children.append(modulesElement(project.modules))
            case PCCElement.connections:
                children.append(connectionsElement(project))
            case PCCElement.projectGraphics:
                children.append(graphicsElement(project.graphics))
            case PCCElement.plcConfiguration:
                if !project.plcConfiguration.isEmpty {
                    children.append(.node(name: PCCElement.plcConfiguration, attrs: [:], children: project.plcConfiguration.map(moduleElement)))
                }
            default:
                // Unmodelled section (CONSTANTS and friends): write back what we read, or an
                // empty element if Dirigo would have written one.
                let raw = project.rawSections.filter { $0.name == name }
                if raw.isEmpty {
                    if name == "CONSTANTS" { children.append(.leaf(name: name, attrs: [:])) }
                } else {
                    children.append(contentsOf: raw.map { resolve($0) })
                }
            }
        }
        return .node(name: PCCElement.root, attrs: a.result, children: children)
    }

    /// The order in which sections are written: the order they appeared in when the project was
    /// read, with any modelled section the file lacked appended in Dirigo's canonical order.
    private func emissionOrder(for project: PCCProject) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for name in project.sectionOrder where seen.insert(name).inserted {
            order.append(name)
        }
        for name in PCCElement.defaultSectionOrder where seen.insert(name).inserted {
            order.append(name)
        }
        if !project.plcConfiguration.isEmpty, seen.insert(PCCElement.plcConfiguration).inserted { order.append(PCCElement.plcConfiguration) }
        // A section the model has no field for is normally in `sectionOrder` because the reader put it there. One that
        // is not — a section this editor was handed rather than read — must still be written, or "raw sections are kept
        // verbatim" would hold only for files that came through the parser.
        for raw in project.rawSections
        where !PCCElement.modelledSections.contains(raw.name) && seen.insert(raw.name).inserted {
            order.append(raw.name)
        }
        return order
    }

    private func resolve(_ raw: RawXMLNode) -> XMLOut {
        let children = raw.children.map { resolve($0) }
        return .node(name: raw.name, attrs: raw.attributes, children: children)
    }

    // MARK: - Sections

    private func communicationElement(_ c: CommunicationConfig) -> XMLOut {
        var a = Attrs(c.rawAttributes)
        a.int("TYPE", c.type)
        a.int("PLC_ADDRESS", c.plcAddress)
        a.int("PC_ADDRESS", c.pcAddress)
        a.int("BAUD_RATE", c.baudRate)
        a.str("HOST", c.host)
        a.int("PORT", c.port)
        a.int("PC_PORT", c.pcPort)
        a.str("PASSWORD", c.password)
        a.int("TIMEOUT", c.timeout)
        return .leaf(name: PCCElement.communication, attrs: a.result)
    }

    private func appOptionsElement(_ o: AppOptions) -> XMLOut {
        var a = Attrs(o.rawAttributes)
        a.int("IQRF_NETWORK", o.iqrfNetwork)
        a.int("IQRF_ADDRESS", o.iqrfAddress)
        a.int("CYCLE_DELAY", o.cycleDelay)
        return .leaf(name: PCCElement.appOptions, attrs: a.result)
    }

    private func simOptionsElement(_ s: SimOptions) -> XMLOut {
        var a = Attrs(s.rawAttributes)
        a.bool("ENABLED", s.enabled)
        a.int("ADDRESS", s.address)
        a.int("PORT", s.port)
        a.str("PASSWORD", s.password)

        let peers: [XMLOut] = s.peers.enumerated().map { idx, peer in
            var pa = Attrs(peer.rawAttributes)
            pa.str("IP", peer.ip)
            pa.int("PORT", peer.port)
            pa.int("TIMEOUT", peer.timeout)
            pa.str("PASSWORD", peer.password)
            return .leaf(name: "PEER_\(idx + 1)", attrs: pa.result)
        }
        return .node(name: PCCElement.simOptions, attrs: a.result, children: peers)
    }

    private func pagesElement(_ pages: [ProjectPage]) -> XMLOut {
        let children = pages.map { page -> XMLOut in
            var a = Attrs(page.rawAttributes)
            a.str("CAPTION", page.caption)
            return .leaf(name: "PAGE", attrs: a.result)
        }
        return .node(name: PCCElement.pages, attrs: [:], children: children)
    }

    private func modulesElement(_ modules: [PCCModule]) -> XMLOut {
        .node(name: PCCElement.modules, attrs: [:], children: modules.map(moduleElement))
    }

    /// A point as Dirigo stores it: a whole number, clamped to a range no page can exceed. A damaged file can carry a
    /// huge or non-finite coordinate, and converting it straight to `Int` would trap while saving.
    private func coordinate(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let limit = 1_000_000_000.0
        return Int(min(max(value.rounded(), -limit), limit))
    }

    private func moduleElement(_ mod: PCCModule) -> XMLOut {
        var a = Attrs(mod.rawAttributes)
        // A GUID this model could not read (a damaged file) stays exactly as the file spells it: replacing it with the
        // stand-in the reader derived would rewrite data the user may be trying to recover.
        if let raw = a.bag["GUID"],
           UUID(uuidString: raw.replacingOccurrences(of: "{", with: "")
                                .replacingOccurrences(of: "}", with: "")) == nil {
            // leave the file's own text alone
        } else {
            a.str("GUID", "{\(mod.guid.uuidString.uppercased())}")
        }
        a.str("NAME", mod.name)
        a.int("ID", mod.id)
        // Dirigo reads every coordinate with `StrToInt`: a fractional one makes it fail to open the file at all
        // ("... is not a valid integer value"). The canvas works in points, so the file gets whole points.
        a.int("X", coordinate(mod.x))
        a.int("Y", coordinate(mod.y))
        a.int("ORDER", mod.order)
        a.int("THREAD_ID", mod.threadId)
        a.str("PAGE", mod.page)
        if let simulMode = mod.simulMode { a.int("SimulMode", simulMode) } else { a.remove("SimulMode") }
        if let inputCount = mod.inputCount { a.int("INPUT_COUNT", inputCount) } else { a.remove("INPUT_COUNT") }

        var children: [XMLOut] = [
            pinsElement(name: "IN_PINS", tag: "IN_PIN", pins: mod.inPins, kind: .input),
            pinsElement(name: "PARAM_PINS", tag: "PARAM_PIN", pins: mod.paramPins, kind: .param),
            pinsElement(name: "OUT_PINS", tag: "OUT_PIN", pins: mod.outPins, kind: .output),
        ]
        // Anything else the module carried is written back untouched.
        children.append(contentsOf: mod.rawChildren.map { resolve($0) })

        return .node(name: "MODULE", attrs: a.result, children: children)
    }

    private enum PinKind { case input, param, output }

    private func pinsElement(name: String, tag: String, pins: [Pin], kind: PinKind) -> XMLOut {
        let children = pins.map { pinElement($0, tag: tag, kind: kind) }
        return .node(name: name, attrs: [:], children: children)
    }

    private func pinElement(_ pin: Pin, tag: String, kind: PinKind) -> XMLOut {
        var a = Attrs(pin.rawAttributes)

        switch kind {
        case .input, .param:
            a.value("VALUE", pin.value)
        case .output:
            // Dirigo only writes VALUE on an output pin when the model actually has one.
            if a.bag["VALUE"] != nil { a.value("VALUE", pin.value) }
        }

        if kind == .input {
            if pin.inverted { a.int("INVERTED", 1) } else { a.remove("INVERTED") }
        }

        if let name = pin.name {
            // Prefer Dirigo's modern spelling; keep a legacy NAME key if that is what was read.
            if a.bag["PIN_NAME"] != nil || a.bag["NAME"] == nil {
                a.str("PIN_NAME", name)
                a.remove("NAME")
            } else {
                a.str("NAME", name)
            }
        }
        if let format = pin.format {
            if a.bag["DISPLAY_FORMAT"] != nil || a.bag["FORMAT"] == nil {
                a.str("DISPLAY_FORMAT", format)
                a.remove("FORMAT")
            } else {
                a.str("FORMAT", format)
            }
        }

        if kind == .output {
            if pin.rights != 0 { a.int("RIGHTS", pin.rights) } else { a.remove("RIGHTS") }
        } else if a.bag["RIGHTS"] != nil {
            a.int("RIGHTS", pin.rights)
        }

        return .leaf(name: tag, attrs: a.result)
    }

    private func connectionsElement(_ project: PCCProject) -> XMLOut {
        let inConns = project.inConnections.map { connectionElement($0) }
        let paramConns = project.paramConnections.map { connectionElement($0) }
        return .node(name: PCCElement.connections, attrs: [:], children: [
            .node(name: "IN_CONNECTIONS", attrs: [:], children: inConns),
            .node(name: "PARAM_CONNECTIONS", attrs: [:], children: paramConns),
        ])
    }

    private func connectionElement(_ conn: Connection) -> XMLOut {
        var a = Attrs(conn.rawAttributes)
        a.int("IN_MODULE_ID", conn.inModuleId)
        a.int("IN_PIN_ID", conn.inPinId)
        a.int("OUT_MODULE_ID", conn.outModuleId)
        a.int("OUT_PIN_ID", conn.outPinId)
        // NAME_X / NAME_Y appear on every connection in some projects and on none in others, so
        // emit them when the file had them, or once they carry a non-zero value.
        if conn.nameX != 0 || a.bag["NAME_X"] != nil { a.int("NAME_X", coordinate(conn.nameX)) }
        if conn.nameY != 0 || a.bag["NAME_Y"] != nil { a.int("NAME_Y", coordinate(conn.nameY)) }

        var children: [XMLOut] = []
        if !conn.points.isEmpty {
            let points = conn.points.map { pt -> XMLOut in
                var pa = Attrs()
                pa.int("X", coordinate(pt.x))
                pa.int("Y", coordinate(pt.y))
                return .leaf(name: "POINT", attrs: pa.result)
            }
            children.append(.node(name: "POINTS", attrs: [:], children: points))
        }
        children.append(contentsOf: conn.rawChildren.map { resolve($0) })

        return .node(name: "CONNECTION", attrs: a.result, children: children)
    }

    private func graphicsElement(_ graphics: [ProjectGraphic]) -> XMLOut {
        .node(name: PCCElement.projectGraphics, attrs: [:], children: graphics.map(graphicElement))
    }

    private func graphicElement(_ g: ProjectGraphic) -> XMLOut {
        var a = Attrs(g.rawAttributes)
        a.int("TYPE", g.type)
        a.str("PAGE", g.page)
        if let text = g.text { a.str("TEXT", text) }

        // The verbatim subtree is authoritative whenever we have one, so a graphic this app has not
        // touched keeps every attribute Dirigo wrote — including the FONT details we do not model.
        // Synthesising from the typed fields is the fallback, used only for graphics built here (see
        // `PCCGraphicBuilder`). Editing a text object changes only its TEXT, which is an attribute
        // and so is written from the typed field either way.
        if !g.rawChildren.isEmpty {
            return .node(name: "GRAPHICS", attrs: a.result, children: g.rawChildren.map { resolve($0) })
        }

        var children: [XMLOut] = []
        if !g.nodes.isEmpty {
            let nodes = g.nodes.map { node -> XMLOut in
                var na = Attrs()
                na.int("X", coordinate(node.x))
                na.int("Y", coordinate(node.y))
                return .leaf(name: "NODE", attrs: na.result)
            }
            children.append(.node(name: "NODES", attrs: [:], children: nodes))
        }
        if let penColor = g.penColor {
            var pa = Attrs()
            pa.str("COLOR", penColor)
            if let mode = g.penMode { pa.int("MODE", mode) }
            if let style = g.penStyle { pa.int("STYLE", style) }
            if let width = g.penWidth { pa.int("WIDTH", width) }
            children.append(.leaf(name: "PEN", attrs: pa.result))
        }
        if let brushColor = g.brushColor {
            var ba = Attrs()
            ba.str("COLOR", brushColor)
            if let style = g.brushStyle { ba.int("STYLE", style) }
            children.append(.leaf(name: "BRUSH", attrs: ba.result))
        }
        if let fontName = g.fontName {
            var fa = Attrs()
            fa.str("NAME", fontName)
            if let bold = g.fontBold { fa.bool("BOLD", bold) }
            if let italic = g.fontItalic { fa.bool("ITALIC", italic) }
            if let size = g.fontSize { fa.int("SIZE", size) }
            if let color = g.fontColor { fa.str("COLOR", color) }
            children.append(.leaf(name: "FONT", attrs: fa.result))
        }
        return .node(name: "GRAPHICS", attrs: a.result, children: children)
    }

    // MARK: - Rendering

    private func render(section node: XMLOut, level: Int, into out: inout String) {
        let indent = String(repeating: "  ", count: level)
        switch node {
        case .leaf(let name, let attrs):
            out += indent + "<" + name + attributeText(attrs) + selfCloseSpace
        case .node(let name, let attrs, let children):
            if children.isEmpty {
                out += indent + "<" + name + attributeText(attrs) + selfCloseSpace
            } else {
                out += indent + "<" + name + attributeText(attrs) + ">\n"
                for (index, child) in children.enumerated() {
                    if index > 0 { out += "\n" }
                    render(section: child, level: level + 1, into: &out)
                }
                out += "\n" + indent + "</" + name + ">"
            }
        }
    }

    private func attributeText(_ attrs: AttributeBag) -> String {
        var out = ""
        for (key, value) in attrs {
            out += " " + key + "=\"" + escape(value) + "\""
        }
        return out
    }

    /// Dirigo escapes tab / newline / carriage return as numeric character references and uses
    /// the named entities for the rest. Reproducing that exactly is what makes the output of an
    /// unmodified project byte-identical to the file Dirigo wrote.
    private func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t": out += "&#9;"
            case "\n": out += "&#xA;"
            case "\r": out += "&#xD;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Attribute merging

    /// Merges modelled values into the attributes a project was read with, keeping the original
    /// spelling whenever the value has not actually changed. That preserves ordering *and*
    /// formatting (`686` stays `686`, `True` stays `True`, `{AB..}` keeps its case).
    private struct Attrs {
        var bag: AttributeBag

        init(_ raw: AttributeBag = [:]) { self.bag = raw }

        var result: AttributeBag { bag }

        mutating func str(_ key: String, _ value: String) {
            if bag[key] != value { bag[key] = value }
        }

        mutating func int(_ key: String, _ value: Int) {
            if let raw = bag[key], Int(raw) == value { return }
            bag[key] = String(value)
        }

        mutating func dbl(_ key: String, _ value: Double) {
            if let raw = bag[key], Double(raw) == value { return }
            bag[key] = Attrs.format(value)
        }

        mutating func bool(_ key: String, _ value: Bool) {
            if let raw = bag[key] {
                let parsed = raw.lowercased() == "true" || raw == "1"
                if parsed == value { return }
            }
            bag[key] = value ? "True" : "False"
        }

        mutating func value(_ key: String, _ value: PinValue) {
            if let raw = bag[key], PinValue.parse(raw) == value { return }
            bag[key] = value.description
        }

        mutating func remove(_ key: String) {
            bag.removeValue(forKey: key)
        }

        /// Integers are written without a decimal point; everything else uses Swift's shortest
        /// round-trippable representation.
        static func format(_ value: Double) -> String {
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        }
    }
}
