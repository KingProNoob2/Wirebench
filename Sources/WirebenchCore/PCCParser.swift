import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum PCCParseError: Error, LocalizedError {
    case invalidXML(String)
    case missingRootElement
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidXML(let msg): return "Invalid XML: \(msg)"
        case .missingRootElement: return "Missing PCC_PROJECT root element"
        case .fileNotFound(let path): return "File not found at path: \(path)"
        }
    }
}

public final class PCCParser: @unchecked Sendable {
    public init() {}    

    public func parse(fileAt url: URL) throws -> PCCProject {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PCCParseError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    public func parse(xmlString: String) throws -> PCCProject {
        guard let data = xmlString.data(using: .utf8) else {
            throw PCCParseError.invalidXML("Failed to encode string to UTF-8")
        }
        return try parse(data: data)
    }

    public func parse(data: Data) throws -> PCCProject {
        let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodePreserveAll])
        guard let root = doc.rootElement(), root.name == "PCC_PROJECT" else {
            throw PCCParseError.missingRootElement
        }

        var project = PCCProject()
        let rawRootAttrs = XMLAttributes.bag(of: root)
        project.rawAttributes = rawRootAttrs
        project.application = rawRootAttrs["APPLICATION"] ?? "Dirigo"
        project.applicationVersion = rawRootAttrs["APPLICATION_VERSION"] ?? ""
        project.name = rawRootAttrs["NAME"] ?? ""
        project.description = rawRootAttrs["DESCRIPTION"] ?? ""
        project.author = rawRootAttrs["AUTHOR"] ?? ""
        project.version = rawRootAttrs["VERSION"] ?? ""
        project.profile = rawRootAttrs["PROFILE"] ?? "Sybas P3"
        project.threadIndex = Int(rawRootAttrs["THREADINDEX"] ?? "4") ?? 4
        project.oldExportMode = (rawRootAttrs["OLD_EXPORT_MODE"]?.lowercased() == "true")
        project.pageSize = Int(rawRootAttrs["PAGESIZE"] ?? "60") ?? 60
        project.applicationPath = rawRootAttrs["APPLICATION_PATH"] ?? ""
        project.projectPath = rawRootAttrs["PROJECT_PATH"] ?? ""
        project.origProjectPath = rawRootAttrs["ORIG_PROJECT_PATH"] ?? ""

        var sectionOrder: [String] = []
        var rawSections: [RawXMLNode] = []
        for child in root.children ?? [] {
            guard let elem = child as? XMLElement, let elemName = elem.name else { continue }
            sectionOrder.append(elemName)

            if !PCCElement.modelledSections.contains(elemName) {
                // Not understood by the object model: keep the whole subtree verbatim so a
                // save cannot drop it.
                rawSections.append(RawXMLNode(elem))
                continue
            }

            switch elemName {
            case PCCElement.communication:
                project.communication = parseCommunication(elem)
            case PCCElement.appOptions:
                project.appOptions = parseAppOptions(elem)
            case PCCElement.simOptions:
                project.simOptions = parseSimOptions(elem)
            case PCCElement.pages:
                project.pages = parsePages(elem)
            case PCCElement.modules:
                project.modules = parseModules(elem)
            case PCCElement.connections:
                let (inConns, paramConns) = parseConnections(elem)
                project.inConnections = inConns
                project.paramConnections = paramConns
            case PCCElement.projectGraphics:
                project.graphics = parseGraphics(elem)
            case PCCElement.plcConfiguration:
                project.plcConfiguration = parseModules(elem)
            default:
                break
            }
        }
        project.sectionOrder = sectionOrder
        project.rawSections = rawSections
        project.selfClosingSpace = Self.detectSelfClosingStyle(in: data)

        return project
    }

    /// Older Dirigo builds write `<TAG attr="v" />`; newer ones write `<TAG attr="v"/>`. The
    /// style is uniform across a file, so a majority vote over the raw bytes is enough — and it
    /// lets a re-save be byte-identical to whatever wrote the project.
    static func detectSelfClosingStyle(in data: Data) -> Bool {
        var spaced = 0
        var tight = 0
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return false }
        for i in 2..<bytes.count where bytes[i] == UInt8(ascii: ">") && bytes[i - 1] == UInt8(ascii: "/") {
            switch bytes[i - 2] {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                spaced += 1
            default:
                tight += 1
            }
        }
        return spaced > tight
    }

    private func parseCommunication(_ elem: XMLElement) -> CommunicationConfig {
        let attrs = XMLAttributes.bag(of: elem)
        return CommunicationConfig(
            type: Int(attrs["TYPE"] ?? "0") ?? 0,
            plcAddress: Int(attrs["PLC_ADDRESS"] ?? "1") ?? 1,
            pcAddress: Int(attrs["PC_ADDRESS"] ?? "31") ?? 31,
            baudRate: Int(attrs["BAUD_RATE"] ?? "57600") ?? 57600,
            host: attrs["HOST"] ?? "127.0.0.1",
            port: Int(attrs["PORT"] ?? "59") ?? 59,
            pcPort: Int(attrs["PC_PORT"] ?? "59") ?? 59,
            password: attrs["PASSWORD"] ?? "",
            timeout: Int(attrs["TIMEOUT"] ?? "5000") ?? 5000,
            rawAttributes: attrs
        )
    }

    private func parseAppOptions(_ elem: XMLElement) -> AppOptions {
        let attrs = XMLAttributes.bag(of: elem)
        return AppOptions(
            iqrfNetwork: Int(attrs["IQRF_NETWORK"] ?? "1") ?? 1,
            iqrfAddress: Int(attrs["IQRF_ADDRESS"] ?? "1") ?? 1,
            cycleDelay: Int(attrs["CYCLE_DELAY"] ?? "7") ?? 7,
            rawAttributes: attrs
        )
    }

    private func parseSimOptions(_ elem: XMLElement) -> SimOptions {
        let attrs = XMLAttributes.bag(of: elem)
        var peers: [PeerConfig] = []
        for child in elem.children ?? [] {
            guard let peerElem = child as? XMLElement, peerElem.name?.hasPrefix("PEER_") == true else { continue }
            let peerAttrs = XMLAttributes.bag(of: peerElem)
            peers.append(PeerConfig(
                ip: peerAttrs["IP"] ?? "127.0.0.1",
                port: Int(peerAttrs["PORT"] ?? "59") ?? 59,
                timeout: Int(peerAttrs["TIMEOUT"] ?? "500") ?? 500,
                password: peerAttrs["PASSWORD"] ?? "",
                rawAttributes: peerAttrs
            ))
        }
        return SimOptions(
            enabled: attrs["ENABLED"]?.lowercased() == "true",
            address: Int(attrs["ADDRESS"] ?? "1") ?? 1,
            port: Int(attrs["PORT"] ?? "59") ?? 59,
            password: attrs["PASSWORD"] ?? "",
            peers: peers,
            rawAttributes: attrs
        )
    }

    private func parsePages(_ elem: XMLElement) -> [ProjectPage] {
        var pages: [ProjectPage] = []
        for child in elem.children ?? [] {
            guard let pageElem = child as? XMLElement, pageElem.name == "PAGE" else { continue }
            let attrs = XMLAttributes.bag(of: pageElem)
            pages.append(ProjectPage(caption: attrs["CAPTION"] ?? "", rawAttributes: attrs))
        }
        return pages
    }

    /// A module's GUID: the file's, or a stand-in derived from the text when the file's is not a GUID.
    ///
    /// `UUID()` would hand the same bytes a different identity on every read, so a project with a damaged GUID would
    /// come back as different blocks each time it was opened, and saving would replace what the file held. A damaged
    /// GUID is still a file someone may want to open and repair, so the stand-in is a function of the text and the
    /// serialiser leaves the file's own spelling alone (see `PCCSerializer.moduleElement`).
    static func guid(from text: String, fallbackSeed: String) -> UUID {
        let clean = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        if let guid = UUID(uuidString: clean) { return guid }
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325      // FNV-1a, and a second pass mixed differently
        var h2: UInt64 = 0x9e37_79b9_7f4a_7c15
        for byte in (text.isEmpty ? fallbackSeed : text).utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            h2 = (h2 ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 &+ 0x9e37_79b9_7f4a_7c15
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: h1 >> (8 * UInt64(i)))
            bytes[i + 8] = UInt8(truncatingIfNeeded: h2 >> (8 * UInt64(i)))
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40             // version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80             // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func parseModules(_ elem: XMLElement) -> [PCCModule] {
        var modules: [PCCModule] = []
        for child in elem.children ?? [] {
            guard let modElem = child as? XMLElement, modElem.name == "MODULE" else { continue }
            let attrs = XMLAttributes.bag(of: modElem)

            let guidStr = attrs["GUID"] ?? ""
            let name = attrs["NAME"] ?? ""
            let guid = Self.guid(from: guidStr, fallbackSeed: "\(name)#\(attrs["ID"] ?? "")")
            let id = Int(attrs["ID"] ?? "0") ?? 0
            let x = Double(attrs["X"] ?? "0") ?? 0
            let y = Double(attrs["Y"] ?? "0") ?? 0
            let order = Int(attrs["ORDER"] ?? "0") ?? 0
            let threadId = Int(attrs["THREAD_ID"] ?? "0") ?? 0
            let page = attrs["PAGE"] ?? ""
            let simulMode = attrs["SimulMode"].flatMap { Int($0) }
            let inputCount = attrs["INPUT_COUNT"].flatMap { Int($0) }

            var inPins: [Pin] = []
            var paramPins: [Pin] = []
            var outPins: [Pin] = []

            var extraChildren: [RawXMLNode] = []
            for subChild in modElem.children ?? [] {
                guard let subElem = subChild as? XMLElement else { continue }
                switch subElem.name {
                case "IN_PINS":
                    inPins = parsePins(subElem, tag: "IN_PIN")
                case "PARAM_PINS":
                    paramPins = parsePins(subElem, tag: "PARAM_PIN")
                case "OUT_PINS":
                    outPins = parsePins(subElem, tag: "OUT_PIN")
                default:
                    extraChildren.append(RawXMLNode(subElem))
                }
            }

            modules.append(PCCModule(
                id: id,
                guid: guid,
                name: name,
                x: x,
                y: y,
                order: order,
                threadId: threadId,
                page: page,
                simulMode: simulMode,
                inputCount: inputCount,
                inPins: inPins,
                paramPins: paramPins,
                outPins: outPins,
                rawAttributes: attrs,
                rawChildren: extraChildren
            ))
        }
        return modules
    }

    private func parsePins(_ elem: XMLElement, tag: String) -> [Pin] {
        var pins: [Pin] = []
        var idx = 0
        for child in elem.children ?? [] {
            guard let pinElem = child as? XMLElement, pinElem.name == tag else { continue }
            let attrs = XMLAttributes.bag(of: pinElem)
            let valStr = attrs["VALUE"] ?? ""
            let val = PinValue.parse(valStr)
            let inverted = (attrs["INVERTED"] == "1" || attrs["INVERTED"]?.lowercased() == "true")
            let rights = Int(attrs["RIGHTS"] ?? "0") ?? 0
            // Dirigo stores these as PIN_NAME / DISPLAY_FORMAT. Older or hand-written files
            // sometimes use NAME / FORMAT, so accept both.
            let name = attrs["PIN_NAME"] ?? attrs["NAME"]
            let format = attrs["DISPLAY_FORMAT"] ?? attrs["FORMAT"]

            pins.append(Pin(
                id: idx,
                value: val,
                inverted: inverted,
                rights: rights,
                name: name,
                format: format,
                rawAttributes: attrs
            ))
            idx += 1
        }
        return pins
    }

    private func parseConnections(_ elem: XMLElement) -> ([Connection], [Connection]) {
        var inConnections: [Connection] = []
        var paramConnections: [Connection] = []

        for child in elem.children ?? [] {
            guard let subElem = child as? XMLElement else { continue }
            if subElem.name == "IN_CONNECTIONS" {
                inConnections = parseConnectionList(subElem, isParam: false)
            } else if subElem.name == "PARAM_CONNECTIONS" {
                paramConnections = parseConnectionList(subElem, isParam: true)
            }
        }
        return (inConnections, paramConnections)
    }

    private func parseConnectionList(_ elem: XMLElement, isParam: Bool) -> [Connection] {
        var conns: [Connection] = []
        for child in elem.children ?? [] {
            guard let connElem = child as? XMLElement, connElem.name == "CONNECTION" else { continue }
            let attrs = XMLAttributes.bag(of: connElem)

            let inMod = Int(attrs["IN_MODULE_ID"] ?? "0") ?? 0
            let inPin = Int(attrs["IN_PIN_ID"] ?? "0") ?? 0
            let outMod = Int(attrs["OUT_MODULE_ID"] ?? "0") ?? 0
            let outPin = Int(attrs["OUT_PIN_ID"] ?? "0") ?? 0
            let nameX = Double(attrs["NAME_X"] ?? "0") ?? 0
            let nameY = Double(attrs["NAME_Y"] ?? "0") ?? 0

            var points: [RoutePoint] = []
            var pointAttrs: [AttributeBag] = []
            var pointsAttrs: AttributeBag = [:]
            var extraChildren: [RawXMLNode] = []
            for pChild in connElem.children ?? [] {
                guard let childElem = pChild as? XMLElement else { continue }
                if childElem.name == "POINTS" {
                    pointsAttrs = XMLAttributes.bag(of: childElem)
                    for ptChild in childElem.children ?? [] {
                        guard let ptElem = ptChild as? XMLElement, ptElem.name == "POINT" else { continue }
                        let attrs = XMLAttributes.bag(of: ptElem)
                        let px = Double(attrs["X"] ?? "0") ?? 0
                        let py = Double(attrs["Y"] ?? "0") ?? 0
                        points.append(RoutePoint(x: px, y: py))
                        pointAttrs.append(attrs)
                    }
                } else {
                    extraChildren.append(RawXMLNode(childElem))
                }
            }

            conns.append(Connection(
                inModuleId: inMod,
                inPinId: inPin,
                outModuleId: outMod,
                outPinId: outPin,
                nameX: nameX,
                nameY: nameY,
                points: points,
                isParam: isParam,
                rawAttributes: attrs,
                rawChildren: extraChildren,
                pointsAttributes: pointsAttrs,
                pointAttributes: pointAttrs
            ))
        }
        return conns
    }

    private func parseGraphics(_ elem: XMLElement) -> [ProjectGraphic] {
        var graphics: [ProjectGraphic] = []
        for child in elem.children ?? [] {
            guard let gElem = child as? XMLElement, gElem.name == "GRAPHICS" else { continue }
            let attrs = XMLAttributes.bag(of: gElem)

            let type = Int(attrs["TYPE"] ?? "0") ?? 0
            let page = attrs["PAGE"] ?? ""
            let text = attrs["TEXT"]

            var nodes: [RoutePoint] = []
            if let nodesElem = gElem.elements(forName: "NODES").first {
                for nChild in nodesElem.children ?? [] {
                    guard let nElem = nChild as? XMLElement, nElem.name == "NODE" else { continue }
                    let nx = Double(nElem.attribute(forName: "X")?.stringValue ?? "0") ?? 0
                    let ny = Double(nElem.attribute(forName: "Y")?.stringValue ?? "0") ?? 0
                    nodes.append(RoutePoint(x: nx, y: ny))
                }
            }

            var penColor: String?
            var penMode: Int?
            var penStyle: Int?
            var penWidth: Int?
            if let penElem = gElem.elements(forName: "PEN").first {
                penColor = penElem.attribute(forName: "COLOR")?.stringValue
                penMode = penElem.attribute(forName: "MODE")?.stringValue.flatMap { Int($0) }
                penStyle = penElem.attribute(forName: "STYLE")?.stringValue.flatMap { Int($0) }
                penWidth = penElem.attribute(forName: "WIDTH")?.stringValue.flatMap { Int($0) }
            }

            var brushColor: String?
            var brushStyle: Int?
            if let brushElem = gElem.elements(forName: "BRUSH").first {
                brushColor = brushElem.attribute(forName: "COLOR")?.stringValue
                brushStyle = brushElem.attribute(forName: "STYLE")?.stringValue.flatMap { Int($0) }
            }

            var fontName: String?
            var fontSize: Int?
            var fontBold: Bool?
            var fontItalic: Bool?
            var fontColor: String?
            if let fontElem = gElem.elements(forName: "FONT").first {
                fontName = fontElem.attribute(forName: "NAME")?.stringValue
                fontSize = fontElem.attribute(forName: "SIZE")?.stringValue.flatMap { Int($0) }
                fontBold = fontElem.attribute(forName: "BOLD")?.stringValue?.lowercased() == "true"
                fontItalic = fontElem.attribute(forName: "ITALIC")?.stringValue?.lowercased() == "true"
                fontColor = fontElem.attribute(forName: "COLOR")?.stringValue
            }

            let verbatimChildren = (gElem.children ?? []).compactMap { $0 as? XMLElement }.map(RawXMLNode.init)

            graphics.append(ProjectGraphic(
                type: type,
                page: page,
                text: text,
                nodes: nodes,
                penColor: penColor,
                penMode: penMode,
                penStyle: penStyle,
                penWidth: penWidth,
                brushColor: brushColor,
                brushStyle: brushStyle,
                fontName: fontName,
                fontSize: fontSize,
                fontBold: fontBold,
                fontItalic: fontItalic,
                fontColor: fontColor,
                rawAttributes: attrs,
                rawChildren: verbatimChildren
            ))
        }
        return graphics
    }
}
