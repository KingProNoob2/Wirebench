import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum MaraflowFormatError: Error, LocalizedError {
    case notMaraflow
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notMaraflow:
            return "This is not a Maraflow project: the file is not a Java properties document."
        case .malformed(let detail):
            return "This Maraflow project is malformed: \(detail)"
        }
    }
}

/// Maraflow stores its `.mfl` projects as Java `Properties` written with `storeToXML`. Everything is a string entry,
/// so this reader keeps the raw key/value pairs and lets the importer interpret them.
struct MaraflowDocument {
    let values: [String: String]

    static func looksLikeDocument(_ data: Data) -> Bool {
        (try? MaraflowDocument(data: data)) != nil
    }

    init(data: Data) throws {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw MaraflowFormatError.notMaraflow
        }
        guard let root = document.rootElement(), root.name == "properties" else {
            throw MaraflowFormatError.notMaraflow
        }
        var values: [String: String] = [:]
        for child in root.children ?? [] {
            guard let entry = child as? XMLElement, entry.name == "entry",
                  let key = entry.attribute(forName: "key")?.stringValue else { continue }
            values[key] = entry.stringValue ?? ""
        }
        self.values = values
    }

    func string(_ key: String, _ fallback: String = "") -> String {
        values[key] ?? fallback
    }

    func int(_ key: String, _ fallback: Int) -> Int {
        guard let raw = values[key], let value = Int(raw) else { return fallback }
        return value
    }

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard let raw = values[key] else { return fallback }
        return raw == "true" || raw == "1"
    }
}

struct MaraflowPin {
    var short: String
    var full: String
    var type: String
    var constant: String
}

struct MaraflowBlock {
    var id: String
    var definitionId: String
    var typeName: String
    var name: String
    var gridX: Int
    var gridY: Int
    var threadId: Int
    var order: Int
    var description: String
    var properties: [(String, String)]
    var inputs: [MaraflowPin]
    var outputs: [MaraflowPin]
}

struct MaraflowWire {
    var sourceBlock: String
    var sourcePin: Int
    var targetBlock: String
    var targetPin: Int
    var hidden: Bool
}

struct MaraflowStVariable {
    var scope: String
    var name: String
    var type: String
    var initial: String
}

struct MaraflowLadderElement {
    var kind: String
    var operand: String
    var sourceOperand: String
    var block: MaraflowBlock?
}

struct MaraflowLadderBranch {
    var start: Int
    var end: Int
    var elements: [MaraflowLadderElement]
}

struct MaraflowRung {
    var comment: String
    var threadID: Int
    var order: Int
    var main: [MaraflowLadderElement]
    var branches: [MaraflowLadderBranch]
    var coils: [MaraflowLadderElement]
}

struct MaraflowGraphic {
    var kind: String
    var gridX: Int
    var gridY: Int
    var gridW: Int
    var gridH: Int
    var strokeRgb: Int
    var fillRgb: Int
    var filled: Bool
    var strokeWidth: Int
    var dashed: Bool
    var text: String
    var fontSize: Int
    var boundTargetPin: String
    var toggleButton: Bool
    var indicatorEnabled: Bool
    var indicatorPin: String
}

struct MaraflowPage {
    var name: String
    var language: String
    var blocks: [MaraflowBlock]
    var wires: [MaraflowWire]
    var stCode: String
    var stVariables: [MaraflowStVariable]
    var stThreadID: Int
    var stOrder: Int
    var rungs: [MaraflowRung]
    var graphics: [MaraflowGraphic]

    var isMacro: Bool { name.hasPrefix("*") }
    var cleanName: String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.first == "*" || clean.first == "!" { clean.removeFirst() }
        return clean.isEmpty ? "Page" : clean
    }
}

struct MaraflowProject {
    var name: String
    var author: String
    var description: String
    var target: String
    var version: String
    var pages: [MaraflowPage]

    static func read(_ document: MaraflowDocument, filename: String) throws -> MaraflowProject {
        let pageCount = max(0, min(document.int("project.pageCount", 1), 2_000))
        var pages: [MaraflowPage] = []
        for index in 0..<pageCount {
            let prefix = "page.\(index)."
            let name = document.string(prefix + "name", "Page \(index + 1)")
            let language = document.string(prefix + "language", "FBD").uppercased()
            let blockCount = max(0, min(document.int(prefix + "blockCount", 0), 100_000))
            var blocks: [MaraflowBlock] = []
            for blockIndex in 0..<blockCount {
                blocks.append(readBlock(document, prefix: prefix + "block.\(blockIndex).", index: blockIndex))
            }
            let wireCount = max(0, min(document.int(prefix + "wireCount", 0), 200_000))
            var wires: [MaraflowWire] = []
            for wireIndex in 0..<wireCount {
                let wirePrefix = prefix + "wire.\(wireIndex)."
                wires.append(MaraflowWire(
                    sourceBlock: document.string(wirePrefix + "srcBlock"),
                    sourcePin: document.int(wirePrefix + "srcPin", 0),
                    targetBlock: document.string(wirePrefix + "dstBlock"),
                    targetPin: document.int(wirePrefix + "dstPin", 0),
                    hidden: document.bool(wirePrefix + "hidden", false)
                ))
            }
            let variableCount = max(0, min(document.int(prefix + "stVarCount", 0), 10_000))
            var variables: [MaraflowStVariable] = []
            for variableIndex in 0..<variableCount {
                let variablePrefix = prefix + "stVar.\(variableIndex)."
                variables.append(MaraflowStVariable(
                    scope: document.string(variablePrefix + "scope", "VAR").uppercased(),
                    name: document.string(variablePrefix + "name", "Var\(variableIndex + 1)"),
                    type: document.string(variablePrefix + "type", "INT").uppercased(),
                    initial: document.string(variablePrefix + "init", "0")
                ))
            }
            let rungCount = max(0, min(document.int(prefix + "rungCount", 0), 10_000))
            let graphicCount = max(0, min(document.int(prefix + "graphicCount", 0), 10_000))
            var graphics: [MaraflowGraphic] = []
            for graphicIndex in 0..<graphicCount {
                let graphicPrefix = prefix + "graphic.\(graphicIndex)."
                graphics.append(MaraflowGraphic(
                    kind: document.string(graphicPrefix + "kind", "RECTANGLE"),
                    gridX: document.int(graphicPrefix + "gridX", 5),
                    gridY: document.int(graphicPrefix + "gridY", 5),
                    gridW: document.int(graphicPrefix + "gridW", 6),
                    gridH: document.int(graphicPrefix + "gridH", 4),
                    strokeRgb: document.int(graphicPrefix + "strokeRgb", -13421773),
                    fillRgb: document.int(graphicPrefix + "fillRgb", -984840),
                    filled: document.bool(graphicPrefix + "filled", false),
                    strokeWidth: document.int(graphicPrefix + "strokeWidth", 1),
                    dashed: document.bool(graphicPrefix + "dashed", false),
                    text: document.string(graphicPrefix + "text", ""),
                    fontSize: document.int(graphicPrefix + "fontSize", 11),
                    boundTargetPin: document.string(graphicPrefix + "boundTargetPin", ""),
                    toggleButton: document.bool(graphicPrefix + "toggleButton", false),
                    indicatorEnabled: document.bool(graphicPrefix + "indicatorEnabled", false),
                    indicatorPin: document.string(graphicPrefix + "indicatorPin", "")
                ))
            }
            var rungs: [MaraflowRung] = []
            for rungIndex in 0..<rungCount {
                let rungPrefix = prefix + "rung.\(rungIndex)."
                let mainCount = max(0, min(document.int(rungPrefix + "mainCount", 0), 512))
                let main = (0..<mainCount).map {
                    readLadderElement(document, prefix: rungPrefix + "main.\($0).")
                }
                let branchCount = max(0, min(document.int(rungPrefix + "branchCount", 0), 512))
                var branches: [MaraflowLadderBranch] = []
                for branchIndex in 0..<branchCount {
                    let branchPrefix = rungPrefix + "branch.\(branchIndex)."
                    let elementCount = max(0, min(document.int(branchPrefix + "elCount", 0), 512))
                    branches.append(MaraflowLadderBranch(
                        start: document.int(branchPrefix + "startCol", 0),
                        end: document.int(branchPrefix + "endCol", 0),
                        elements: (0..<elementCount).map {
                            readLadderElement(document, prefix: branchPrefix + "el.\($0).")
                        }))
                }
                let coilCount = max(0, min(document.int(rungPrefix + "coilCount", 0), 512))
                let coils = (0..<coilCount).map {
                    readLadderElement(document, prefix: rungPrefix + "coil.\($0).")
                }
                rungs.append(MaraflowRung(comment: document.string(rungPrefix + "comment"),
                                          threadID: document.int(rungPrefix + "threadId", 2),
                                          order: document.int(rungPrefix + "order", (rungIndex + 1) * 10),
                                          main: main, branches: branches, coils: coils))
            }
            pages.append(MaraflowPage(
                name: name,
                language: language,
                blocks: blocks,
                wires: wires,
                stCode: document.string(prefix + "stCode"),
                stVariables: variables,
                stThreadID: document.int(prefix + "stThreadId", 2),
                stOrder: document.int(prefix + "stOrder", 10),
                rungs: rungs,
                graphics: graphics
            ))
        }
        if pages.isEmpty { pages = [MaraflowPage(name: "Page 1", language: "FBD", blocks: [], wires: [],
                                                 stCode: "", stVariables: [], stThreadID: 2, stOrder: 10,
                                                 rungs: [], graphics: [])] }
        return MaraflowProject(
            name: document.string("project.name", filename),
            author: document.string("project.author"),
            description: document.string("project.description"),
            target: document.string("project.targetPlatform"),
            version: document.string("maraflow.version"),
            pages: pages
        )
    }

    private static func readLadderElement(_ document: MaraflowDocument, prefix: String) -> MaraflowLadderElement {
        let kind = document.string(prefix + "kind", "NO_CONTACT")
        let block = kind == "FUNCTION_BLOCK" ? readBlock(document, prefix: prefix + "fb.", index: 0) : nil
        return MaraflowLadderElement(kind: kind,
                                     operand: document.string(prefix + "operand"),
                                     sourceOperand: document.string(prefix + "srcOperand"),
                                     block: block)
    }

    private static func readBlock(_ document: MaraflowDocument, prefix: String, index: Int) -> MaraflowBlock {
        func readPins(_ side: String, countKey: String) -> [MaraflowPin] {
            let count = max(0, min(document.int(prefix + countKey, 0), 256))
            return (0..<count).map { pinIndex in
                let pinPrefix = prefix + side + ".\(pinIndex)."
                return MaraflowPin(short: document.string(pinPrefix + "short", "P\(pinIndex)"),
                                   full: document.string(pinPrefix + "full"),
                                   type: document.string(pinPrefix + "type", "BOOL").uppercased(),
                                   constant: document.string(pinPrefix + "const", "0"))
            }
        }
        let propertyCount = max(0, min(document.int(prefix + "propCount", 0), 1_000))
        var properties: [(String, String)] = []
        for propertyIndex in 0..<propertyCount {
            let key = document.string(prefix + "prop.\(propertyIndex).k")
            let value = document.string(prefix + "prop.\(propertyIndex).v")
            if !key.isEmpty { properties.append((key, value)) }
        }
        let definitionId = document.string(prefix + "defId", "Bool.And")
        let typeName = document.string(prefix + "typeName", definitionId.split(separator: ".").last.map(String.init) ?? "Block")
        return MaraflowBlock(
            id: document.string(prefix + "id", "block-\(index)"),
            definitionId: definitionId,
            typeName: typeName,
            name: document.string(prefix + "name", typeName + "\(index + 1)"),
            gridX: document.int(prefix + "gridX", 10),
            gridY: document.int(prefix + "gridY", 10),
            threadId: document.int(prefix + "threadId", 2),
            order: document.int(prefix + "order", (index + 1) * 10),
            description: document.string(prefix + "description"),
            properties: properties,
            inputs: readPins("in", countKey: "inCount"),
            outputs: readPins("out", countKey: "outCount")
        )
    }
}
