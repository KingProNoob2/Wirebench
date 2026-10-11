import Testing
import Foundation
@testable import DirigoCore

/// Guards the one thing that makes this reimplementation safe to use alongside the original:
/// **every XML name we can emit must be one Dirigo defines**, and `PAGESIZE` must be passed
/// through untouched.
///
/// The name lists below are extracted from the IDE binaries (the writer's string table, plus
/// `PccBase.bpl` for the pin attributes) and cross-checked against Dirigo-written `.pcc` files.
/// If you add an element or attribute to the serializer, add it to the right list here — or better,
/// to Dirigo's, because otherwise the original will not understand the file.
@Suite("Dirigo schema conformance")
struct SchemaConformanceTests {
    /// Names the IDE's XML writer uses. Source: `Dirigo_unpacked.idp` string table.
    static let dirigoProjectNames: Set<String> = [
        "PCC_PROJECT", "Dirigo", "APPLICATION", "APPLICATION_VERSION", "NAME", "DESCRIPTION",
        "AUTHOR", "VERSION", "PROFILE", "THREADINDEX", "OLD_EXPORT_MODE", "PAGESIZE",
        "AUTO_RENUMBER", "COMMUNICATION", "COMM_DEFAULTS", "APPLICATION_PATH", "PROJECT_PATH",
        "ORIG_PROJECT_PATH", "APP_OPTIONS", "IQRF_NETWORK", "IQRF_ADDRESS", "CYCLE_DELAY",
        "SIM_OPTIONS", "ENABLED", "ADDRESS", "PORT", "PASSWORD", "PEER_", "IP", "TIMEOUT",
        "PAGES", "PAGE", "CAPTION", "READONLY", "HIDDEN", "CONSTANTS", "CONSTANT", "ID",
        "DATA_TYPE", "VALUE", "KIND", "INFO1", "INFO2", "INFO3", "RIGHTS", "ARRAY_INDEX",
        "MODULES", "MODULE", "CONNECTIONS", "IN_CONNECTIONS", "PARAM_CONNECTIONS",
        "PROJECT_GRAPHICS", "GRAPHICS", "TYPE", "GRAPH_PRESETS", "PRESET", "SIGNAL",
        "IN_MODULE_ID", "IN_PIN_ID", "OUT_MODULE_ID", "OUT_PIN_ID", "NAME_X", "NAME_Y",
        "WIDTH", "COLOR", "REVERSE", "POINTS", "POINT", "PLC_ADDRESS", "PC_ADDRESS",
        "BAUD_RATE", "PARITY", "NONE", "HOST", "PC_PORT",
        // Module / pin / graphics attributes attested in Dirigo-written .pcc files
        // (PIN_NAME and DISPLAY_FORMAT also appear in PccBase.bpl).
        "GUID", "X", "Y", "ORDER", "THREAD_ID", "INPUT_COUNT", "SimulMode", "PIN_NAME",
        "DISPLAY_FORMAT", "INVERTED", "TEXT", "NODES", "NODE", "PEN", "BRUSH", "FONT",
        "MODE", "STYLE", "BOLD", "ITALIC", "SIZE", "NAME", "IN_PINS", "IN_PIN", "PARAM_PINS",
        "PARAM_PIN", "OUT_PINS", "OUT_PIN", "CONNECTION", "PEER", "PEER_1", "PEER_2",
        // Font serialisation attributes.
        "CHARSET", "UNDERLINE", "STRIKE_OUT",
        // Module attributes Dirigo writes and we carry through untouched.
        "LIMIT", "MACRO_NAME", "MODULO_VISIBLE", "OUTPUT_COUNT", "PIN_COUNT", "PIN_MASK",
        "HIDDEN_PIN_MASK",
    ]

    static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Names that are legitimate because a Dirigo-written project already uses them.
    static func namesInProjectFiles() -> Set<String> {
        var names: Set<String> = []
        for name in ["rulkoshaddirigo.pcc", "ruleta_kostka_had.pcc"] {
            let url = workspace.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            names.formUnion(xmlNames(in: text))
        }
        return names
    }

    @Test("A reserialized project only uses names Dirigo knows")
    func noInventedNames() throws {
        // Allowed = every name Dirigo's own writer uses, plus every name already present in a
        // Dirigo-written project. Anything outside that union is something we made up.
        let allowed = Self.dirigoProjectNames.union(Self.namesInProjectFiles())
        try #require(allowed.count > 50, "no sample projects found to derive the allowed set from")

        for name in ["rulkoshaddirigo.pcc", "ruleta_kostka_had.pcc"] {
            let url = Self.workspace.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let project = try PCCParser().parse(fileAt: url)
            let xml = PCCSerializer().serialize(project: project)
            let unknown = Self.xmlNames(in: xml).subtracting(allowed)
            #expect(unknown.isEmpty,
                    "\(name): serializer emitted names Dirigo does not define: \(unknown.sorted())")
        }
    }

    @Test("PAGESIZE is preserved byte-for-byte on save")
    func pageSizePreserved() throws {
        let url = Self.workspace.appendingPathComponent("rulkoshaddirigo.pcc")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let project = try PCCParser().parse(fileAt: url)
        let xml = PCCSerializer().serialize(project: project)
        #expect(xml.contains("PAGESIZE=\"\(project.pageSize)\""))
    }

    /// Collects every element and attribute name in an XML string.
    ///
    /// Tokenises inside `<...>` only, and steps over quoted attribute values so that spaces or
    /// Czech text inside a value can never be mistaken for a name.
    static func xmlNames(in xml: String) -> Set<String> {
        var names: Set<String> = []
        var index = xml.startIndex

        while let open = xml[index...].firstIndex(of: "<") {
            guard let close = xml[open...].firstIndex(of: ">") else { break }
            var i = xml.index(after: open)
            index = xml.index(after: close)

            if i < close, xml[i] == "/" || xml[i] == "?" || xml[i] == "!" { continue }

            while i < close {
                while i < close, xml[i] == " " { i = xml.index(after: i) }
                guard i < close else { break }

                // Read the token up to '=', whitespace, or the self-closing slash.
                var token = ""
                while i < close, xml[i] != "=", xml[i] != " ", xml[i] != "/" {
                    token.append(xml[i])
                    i = xml.index(after: i)
                }
                if !token.isEmpty { names.insert(token) }

                // If it is an attribute, step over the quoted value wholesale.
                if i < close, xml[i] == "=" {
                    i = xml.index(after: i)
                    if i < close, xml[i] == "\"" || xml[i] == "'" {
                        let quote = xml[i]
                        i = xml.index(after: i)
                        while i < close, xml[i] != quote { i = xml.index(after: i) }
                        if i < close { i = xml.index(after: i) }
                    }
                } else if token.isEmpty {
                    // A self-closing '/', or anything else we do not consume: step over it, or the
                    // loop never advances. (This hung the suite when it was first written.)
                    i = xml.index(after: i)
                }
            }
        }
        return names
    }
}
