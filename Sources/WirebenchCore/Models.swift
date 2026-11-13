import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Represents the data value flowing through a pin on a wire.
public enum PinValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case bool(Bool)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case float(Float)
    case undefined

    /// Equality with one deliberate difference from the synthesised one: **NaN equals NaN**.
    ///
    /// A float pin can hold NaN — `FMul` overflowing, a division, a `nan` in a file that is then written back as
    /// `nan` — and a value read back from such a file is the same value. The synthesised `==` says otherwise, so a
    /// project holding one is never equal to its own reloaded copy, and `PinValue`'s `Hashable` conformance would be
    /// inconsistent with its `==` (`Set` would keep two NaNs). Canonicing the NaN in `hash(into:)` keeps the two
    /// halves of the conformance agreeing.
    public static func == (a: PinValue, b: PinValue) -> Bool {
        switch (a, b) {
        case (.bool(let x), .bool(let y)): return x == y
        case (.int16(let x), .int16(let y)): return x == y
        case (.int32(let x), .int32(let y)): return x == y
        case (.int64(let x), .int64(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y || (x.isNaN && y.isNaN)
        case (.undefined, .undefined): return true
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .bool(let v): hasher.combine(0); hasher.combine(v)
        case .int16(let v): hasher.combine(1); hasher.combine(v)
        case .int32(let v): hasher.combine(2); hasher.combine(v)
        case .int64(let v): hasher.combine(3); hasher.combine(v)
        case .float(let v): hasher.combine(4); hasher.combine(v.isNaN ? Float.nan : v)
        case .undefined: hasher.combine(5)
        }
    }

    public var asBool: Bool {
        switch self {
        case .bool(let v): return v
        case .int16(let v): return v != 0
        case .int32(let v): return v != 0
        case .int64(let v): return v != 0
        case .float(let v): return v != 0.0
        case .undefined: return false
        }
    }

    public var asInt: Int {
        switch self {
        case .bool(let v): return v ? 1 : 0
        case .int16(let v): return Int(v)
        case .int32(let v): return Int(v)
        case .int64(let v): return Int(v)
        case .float(let v): return Int(Self.saturating(v))
        case .undefined: return 0
        }
    }

    public var asInt32: Int32 {
        switch self {
        case .bool(let v): return v ? 1 : 0
        case .int16(let v): return Int32(v)
        case .int32(let v): return v
        case .int64(let v): return Int32(truncatingIfNeeded: v)
        case .float(let v): return Self.saturating(v)
        case .undefined: return 0
        }
    }

    /// A float as an `Int32`, truncated toward zero. `Int32(v)` traps on NaN, infinity and anything out
    /// of range — all of which float arithmetic produces (`FMul` overflowing, a large typed value) — so
    /// those clamp to the range, and NaN reads as 0.
    static func saturating(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        if v >= 2_147_483_648 { return .max }
        if v <= -2_147_483_648 { return .min }
        return Int32(v)
    }

    public var asFloat: Float {
        switch self {
        case .bool(let v): return v ? 1.0 : 0.0
        case .int16(let v): return Float(v)
        case .int32(let v): return Float(v)
        case .int64(let v): return Float(v)
        case .float(let v): return v
        case .undefined: return 0.0
        }
    }

    public var description: String {
        switch self {
        case .bool(let v): return v ? "1" : "0"
        case .int16(let v): return "\(v)"
        case .int32(let v): return "\(v)"
        case .int64(let v): return "\(v)"
        case .float(let v): return "\(v)"
        case .undefined: return "undefined"
        }
    }

    public static func parse(_ string: String) -> PinValue {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .undefined }
        
        // Check for hex ($1234 or 0x1234)
        if trimmed.hasPrefix("$") {
            let hexStr = String(trimmed.dropFirst())
            if let val = Int32(hexStr, radix: 16) {
                return .int32(val)
            }
        }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            let hexStr = String(trimmed.dropFirst(2))
            if let val = Int32(hexStr, radix: 16) {
                return .int32(val)
            }
        }
        
        // Check for binary (0b11110000 or 0B11110000)
        if trimmed.hasPrefix("0b") || trimmed.hasPrefix("0B") {
            let binStr = String(trimmed.dropFirst(2))
            if let val = Int32(binStr, radix: 2) {
                return .int32(val)
            }
        }
        
        // Integer
        if let val = Int32(trimmed) {
            return .int32(val)
        }
        // Float
        if let val = Float(trimmed) {
            return .float(val)
        }
        // Boolean
        if trimmed.lowercased() == "true" { return .bool(true) }
        if trimmed.lowercased() == "false" { return .bool(false) }
        
        return .undefined
    }
}

public struct Pin: Identifiable, Sendable, Codable, Equatable {
    public var id: Int
    public var value: PinValue
    public var inverted: Bool
    public var rights: Int
    public var name: String?
    public var format: String?
    public var rawAttributes: AttributeBag

    public init(
        id: Int,
        value: PinValue = .undefined,
        inverted: Bool = false,
        rights: Int = 0,
        name: String? = nil,
        format: String? = nil,
        rawAttributes: AttributeBag = [:]
    ) {
        self.id = id
        self.value = value
        self.inverted = inverted
        self.rights = rights
        self.name = name
        self.format = format
        self.rawAttributes = rawAttributes
    }
}

public struct PCCModule: Identifiable, Sendable, Codable, Equatable {
    public var id: Int
    public var guid: UUID
    public var name: String
    public var x: Double
    public var y: Double
    public var order: Int
    public var threadId: Int
    public var page: String
    public var simulMode: Int?
    public var inputCount: Int?
    public var inPins: [Pin]
    public var paramPins: [Pin]
    public var outPins: [Pin]
    public var rawAttributes: AttributeBag
    /// Children of `<MODULE>` other than IN_PINS / PARAM_PINS / OUT_PINS, kept verbatim.
    public var rawChildren: [RawXMLNode]

    public init(
        id: Int,
        guid: UUID,
        name: String,
        x: Double,
        y: Double,
        order: Int,
        threadId: Int,
        page: String,
        simulMode: Int? = nil,
        inputCount: Int? = nil,
        inPins: [Pin] = [],
        paramPins: [Pin] = [],
        outPins: [Pin] = [],
        rawAttributes: AttributeBag = [:],
        rawChildren: [RawXMLNode] = []
    ) {
        self.id = id
        self.guid = guid
        self.name = name
        self.x = x
        self.y = y
        self.order = order
        self.threadId = threadId
        self.page = page
        self.simulMode = simulMode
        self.inputCount = inputCount
        self.inPins = inPins
        self.paramPins = paramPins
        self.outPins = outPins
        self.rawAttributes = rawAttributes
        self.rawChildren = rawChildren
    }
}

public struct RoutePoint: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Connection: Sendable, Codable, Equatable {
    public var inModuleId: Int
    public var inPinId: Int
    public var outModuleId: Int
    public var outPinId: Int
    public var nameX: Double
    public var nameY: Double
    public var points: [RoutePoint]
    public var isParam: Bool
    /// Every attribute of `<CONNECTION>` as read, order preserved.
    public var rawAttributes: AttributeBag
    /// Children of `<CONNECTION>` this model does not understand, kept verbatim.
    public var rawChildren: [RawXMLNode]
    /// Attributes of the `<POINTS>` element, and of each `<POINT>`, kept so a save does not drop them.
    public var pointsAttributes: AttributeBag
    public var pointAttributes: [AttributeBag]

    public init(
        inModuleId: Int,
        inPinId: Int,
        outModuleId: Int,
        outPinId: Int,
        nameX: Double = 0,
        nameY: Double = 0,
        points: [RoutePoint] = [],
        isParam: Bool = false,
        rawAttributes: AttributeBag = [:],
        rawChildren: [RawXMLNode] = [],
        pointsAttributes: AttributeBag = [:],
        pointAttributes: [AttributeBag] = []
    ) {
        self.inModuleId = inModuleId
        self.inPinId = inPinId
        self.outModuleId = outModuleId
        self.outPinId = outPinId
        self.nameX = nameX
        self.nameY = nameY
        self.points = points
        self.isParam = isParam
        self.rawAttributes = rawAttributes
        self.rawChildren = rawChildren
        self.pointsAttributes = pointsAttributes
        self.pointAttributes = pointAttributes
    }
}

public struct ProjectPage: Identifiable, Sendable, Codable, Equatable {
    public var id: String { caption }
    public var caption: String
    /// Every attribute of `<PAGE>` as read, order preserved. Dirigo also stores `READONLY` and
    /// `HIDDEN` here (both confirmed present in the IDE's XML name table); without this they were
    /// silently dropped on save.
    public var rawAttributes: AttributeBag

    public init(caption: String, rawAttributes: AttributeBag = [:]) {
        self.caption = caption
        self.rawAttributes = rawAttributes
    }
}

public struct CommunicationConfig: Sendable, Codable, Equatable {
    public var type: Int
    public var plcAddress: Int
    public var pcAddress: Int
    public var baudRate: Int
    public var host: String
    public var port: Int
    public var pcPort: Int
    public var password: String
    public var timeout: Int
    public var rawAttributes: AttributeBag

    public init(
        type: Int = 0,
        plcAddress: Int = 1,
        pcAddress: Int = 31,
        baudRate: Int = 57600,
        host: String = "127.0.0.1",
        port: Int = 59,
        pcPort: Int = 59,
        password: String = "",
        timeout: Int = 5000,
        rawAttributes: AttributeBag = [:]
    ) {
        self.type = type
        self.plcAddress = plcAddress
        self.pcAddress = pcAddress
        self.baudRate = baudRate
        self.host = host
        self.port = port
        self.pcPort = pcPort
        self.password = password
        self.timeout = timeout
        self.rawAttributes = rawAttributes
    }
}

public struct AppOptions: Sendable, Codable, Equatable {
    public var iqrfNetwork: Int
    public var iqrfAddress: Int
    public var cycleDelay: Int
    public var rawAttributes: AttributeBag

    public init(
        iqrfNetwork: Int = 1,
        iqrfAddress: Int = 1,
        cycleDelay: Int = 7,
        rawAttributes: AttributeBag = [:]
    ) {
        self.iqrfNetwork = iqrfNetwork
        self.iqrfAddress = iqrfAddress
        self.cycleDelay = cycleDelay
        self.rawAttributes = rawAttributes
    }
}

public struct PeerConfig: Sendable, Codable, Equatable {
    public var ip: String
    public var port: Int
    public var timeout: Int
    public var password: String
    public var rawAttributes: AttributeBag

    public init(ip: String, port: Int, timeout: Int, password: String, rawAttributes: AttributeBag = [:]) {
        self.ip = ip
        self.port = port
        self.timeout = timeout
        self.password = password
        self.rawAttributes = rawAttributes
    }
}

public struct SimOptions: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var address: Int
    public var port: Int
    public var password: String
    public var peers: [PeerConfig]
    public var rawAttributes: AttributeBag

    public init(
        enabled: Bool = false,
        address: Int = 1,
        port: Int = 59,
        password: String = "",
        peers: [PeerConfig] = [],
        rawAttributes: AttributeBag = [:]
    ) {
        self.enabled = enabled
        self.address = address
        self.port = port
        self.password = password
        self.peers = peers
        self.rawAttributes = rawAttributes
    }
}

public struct ProjectGraphic: Sendable, Codable, Equatable {
    public var type: Int
    public var page: String
    public var text: String?
    public var nodes: [RoutePoint]
    public var penColor: String?
    public var penMode: Int?
    public var penStyle: Int?
    public var penWidth: Int?
    public var brushColor: String?
    public var brushStyle: Int?
    public var fontName: String?
    public var fontSize: Int?
    public var fontBold: Bool?
    public var fontItalic: Bool?
    public var fontColor: String?
    public var rawAttributes: AttributeBag
    /// Every child of `<GRAPHICS>`, verbatim (NODES, PEN, BRUSH, FONT, and anything else).
    /// When non-empty the serializer writes these back unchanged, which is what makes graphic
    /// objects lossless. Build a `PCCGraphicBuilder` to construct one from the typed fields.
    public var rawChildren: [RawXMLNode]

    public init(
        type: Int,
        page: String,
        text: String? = nil,
        nodes: [RoutePoint] = [],
        penColor: String? = nil,
        penMode: Int? = nil,
        penStyle: Int? = nil,
        penWidth: Int? = nil,
        brushColor: String? = nil,
        brushStyle: Int? = nil,
        fontName: String? = nil,
        fontSize: Int? = nil,
        fontBold: Bool? = nil,
        fontItalic: Bool? = nil,
        fontColor: String? = nil,
        rawAttributes: AttributeBag = [:],
        rawChildren: [RawXMLNode] = []
    ) {
        self.type = type
        self.page = page
        self.text = text
        self.nodes = nodes
        self.penColor = penColor
        self.penMode = penMode
        self.penStyle = penStyle
        self.penWidth = penWidth
        self.brushColor = brushColor
        self.brushStyle = brushStyle
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontBold = fontBold
        self.fontItalic = fontItalic
        self.fontColor = fontColor
        self.rawAttributes = rawAttributes
        self.rawChildren = rawChildren
    }
}

public struct PCCProject: Sendable, Codable, Equatable {
    public var application: String
    public var applicationVersion: String
    public var name: String
    public var description: String
    public var author: String
    public var version: String
    public var profile: String
    public var threadIndex: Int
    public var oldExportMode: Bool
    public var pageSize: Int
    public var applicationPath: String
    public var projectPath: String
    public var origProjectPath: String
    public var rawAttributes: AttributeBag
    /// Names of the direct children of `<PCC_PROJECT>`, in document order.
    public var sectionOrder: [String]
    /// Top-level sections the object model does not understand (e.g. `CONSTANTS`), kept
    /// verbatim so they survive a save.
    public var rawSections: [RawXMLNode]
    /// Dirigo changed its XML writer at some point: older builds emit `<TAG ... />` and newer
    /// ones `<TAG .../>`. The style is uniform within a file, so it is detected once when the
    /// project is read and reproduced when it is written.
    public var selfClosingSpace: Bool

    public var communication: CommunicationConfig
    public var appOptions: AppOptions
    public var simOptions: SimOptions
    public var pages: [ProjectPage]
    public var modules: [PCCModule]
    public var inConnections: [Connection]
    public var paramConnections: [Connection]
    public var graphics: [ProjectGraphic]
    /// The project's PLC configuration: `SystemCmd` blocks held as configuration entries instead of blocks on a sheet (`PLCConfiguration`). Each is
    /// the block itself, so that writing it back as a block reproduces the original exactly; one an editor made has no page yet (`page == ""`).
    public var plcConfiguration: [PCCModule]

    public init(
        application: String = "Dirigo",
        applicationVersion: String = "v2.5.9.449",
        name: String = "",
        description: String = "",
        author: String = "",
        version: String = "",
        profile: String = "Sybas P3",
        threadIndex: Int = 4,
        oldExportMode: Bool = false,
        pageSize: Int = 60,
        applicationPath: String = "",
        projectPath: String = "",
        origProjectPath: String = "",
        rawAttributes: AttributeBag = [:],
        sectionOrder: [String] = PCCElement.defaultSectionOrder,
        rawSections: [RawXMLNode] = [],
        selfClosingSpace: Bool = false,
        communication: CommunicationConfig = CommunicationConfig(),
        appOptions: AppOptions = AppOptions(),
        simOptions: SimOptions = SimOptions(),
        pages: [ProjectPage] = [],
        modules: [PCCModule] = [],
        inConnections: [Connection] = [],
        paramConnections: [Connection] = [],
        graphics: [ProjectGraphic] = [],
        plcConfiguration: [PCCModule] = []
    ) {
        self.application = application
        self.applicationVersion = applicationVersion
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.profile = profile
        self.threadIndex = threadIndex
        self.oldExportMode = oldExportMode
        self.pageSize = pageSize
        self.applicationPath = applicationPath
        self.projectPath = projectPath
        self.origProjectPath = origProjectPath
        self.rawAttributes = rawAttributes
        self.sectionOrder = sectionOrder
        self.rawSections = rawSections
        self.selfClosingSpace = selfClosingSpace
        self.communication = communication
        self.appOptions = appOptions
        self.simOptions = simOptions
        self.pages = pages
        self.modules = modules
        self.inConnections = inConnections
        self.paramConnections = paramConnections
        self.graphics = graphics
        self.plcConfiguration = plcConfiguration
    }
}


// MARK: - Renaming a page

public extension PCCProject {
    /// Renames a sheet — a normal page, not a macro one (`renameMacroSheet` in `MacroInterface` does those, because its call
    /// sites have to follow the name).
    ///
    /// Blocks, graphic objects and the project's PLC configuration entries name their page by caption, so the rename has to
    /// carry them; a page renamed alone would strand them — no sheet would draw them, and the file would keep them.
    ///
    /// Refused when the name is empty, belongs to another page (a difference of case alone is this page being renamed), or
    /// starts with `*`: that prefix is what makes a page a macro sheet, and a macro sheet needs its interface blocks.
    @discardableResult
    mutating func renamePage(from old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.hasPrefix("*"), !trimmed.hasPrefix("*"), !trimmed.isEmpty,
              pages.contains(where: { $0.caption == old }),
              !pages.contains(where: { $0.caption.lowercased() == trimmed.lowercased() && $0.caption != old })
        else { return false }
        for i in pages.indices where pages[i].caption == old { pages[i].caption = trimmed }
        for i in modules.indices where modules[i].page == old { modules[i].page = trimmed }
        for i in graphics.indices where graphics[i].page == old { graphics[i].page = trimmed }
        for i in plcConfiguration.indices where plcConfiguration[i].page == old { plcConfiguration[i].page = trimmed }
        return true
    }
}

// MARK: - Wiring

extension PCCProject {
    /// Why a proposed connection was refused.
    public enum ConnectionError: Error, Equatable, Sendable {
        case unknownPin
        case alreadyConnected
    }

    /// Connects an output pin to an input pin, or — with `toParam` — to a **parameter** pin, which Dirigo draws among the inputs and wires
    /// the same way (the connection is kept in `PARAM_CONNECTIONS`).
    ///
    /// The original's rules, from `GrafickeOkno.html`: wiring runs **input to output**, an output may
    /// feed many inputs, and an input holds exactly one connection. So connecting to an input that is
    /// already wired **replaces** that wire rather than being refused — that is how the original
    /// behaves when you drag onto an occupied input.
    @discardableResult
    public mutating func connect(outModuleId: Int, outPinId: Int,
                                 toModuleId: Int, inPinId: Int, toParam: Bool = false) -> ConnectionError? {
        guard let source = modules.first(where: { $0.id == outModuleId }),
              let destination = modules.first(where: { $0.id == toModuleId }),
              outPinId >= 0, outPinId < source.outPins.count,
              inPinId >= 0, inPinId < (toParam ? destination.paramPins.count : destination.inPins.count)
        else { return .unknownPin }

        func same(_ c: Connection) -> Bool { c.inModuleId == toModuleId && c.inPinId == inPinId }
        if toParam {
            if paramConnections.contains(where: { same($0) && $0.outModuleId == outModuleId && $0.outPinId == outPinId }) {
                return .alreadyConnected
            }
            paramConnections.removeAll { same($0) }
            paramConnections.append(Connection(inModuleId: toModuleId, inPinId: inPinId,
                                               outModuleId: outModuleId, outPinId: outPinId, isParam: true))
            return nil
        }

        if inConnections.contains(where: { same($0) && $0.outModuleId == outModuleId && $0.outPinId == outPinId }) {
            return .alreadyConnected
        }

        // An input takes exactly one source.
        inConnections.removeAll { same($0) }
        inConnections.append(Connection(inModuleId: toModuleId, inPinId: inPinId,
                                        outModuleId: outModuleId, outPinId: outPinId))
        return nil
    }

    /// Removes whatever is wired to an input pin (or parameter pin). Outputs are never removed directly, because an
    /// output's wires are owned by the inputs they feed.
    @discardableResult
    public mutating func disconnect(inModuleId: Int, inPinId: Int, param: Bool = false) -> Bool {
        if param {
            let before = paramConnections.count
            paramConnections.removeAll { $0.inModuleId == inModuleId && $0.inPinId == inPinId }
            return paramConnections.count != before
        }
        let before = inConnections.count
        inConnections.removeAll { $0.inModuleId == inModuleId && $0.inPinId == inPinId }
        return inConnections.count != before
    }

    /// The connection feeding an input pin (or parameter pin), if any.
    public func connection(inModuleId: Int, inPinId: Int, param: Bool = false) -> Connection? {
        (param ? paramConnections : inConnections).first { $0.inModuleId == inModuleId && $0.inPinId == inPinId }
    }

    /// Every connection leaving an output pin. One output may drive many inputs.
    public func connections(outModuleId: Int, outPinId: Int) -> [Connection] {
        (inConnections + paramConnections).filter { $0.outModuleId == outModuleId && $0.outPinId == outPinId }
    }
}
