import Foundation

/// Everything a Maraflow project carries that the Dirigo-derived model has no field for.
///
/// The `.mfl` format is a flat properties document; keeping its keys verbatim is the only way to promise that an
/// import loses nothing today, including fields Wirebench does not interpret yet (tags, E-Stop rules, graphics, bus
/// ids, wire routes, ST order). The typed views below are computed over that table for the inspector and CLI.
public struct MaraflowExtras: Codable, Sendable, Equatable {
    /// The `.mfl` schema this project came from (`maraflow.version` when present).
    public var formatVersion: String
    /// Every key and value read from the `.mfl`, including keys this build does not understand.
    public var properties: [String: String]

    public init(formatVersion: String = "", properties: [String: String]) {
        self.formatVersion = formatVersion
        self.properties = properties
    }

    public struct Tag: Sendable, Equatable {
        public let name: String
        public let type: String
        public let description: String
    }

    public struct EStopRule: Sendable, Equatable {
        public let channel: String
        public let activeLow: Bool
        public let enabled: Bool
        public let description: String
    }

    public struct EStop: Sendable, Equatable {
        public let enabled: Bool
        public let mode: String
        public let pageName: String
        public let manualReset: Bool
        public let rules: [EStopRule]
    }

    public struct BusSummary: Sendable, Equatable {
        public let id: String
        public let wireCount: Int
        public let hiddenCount: Int
        public let netNames: [String]
    }

    public struct PageSummary: Sendable, Equatable {
        public let name: String
        public let language: String
        public let blocks: Int
        public let wires: Int
        public let graphics: Int
        public let rungs: Int
    }

    private func integer(_ key: String, _ fallback: Int = 0) -> Int {
        properties[key].flatMap(Int.init) ?? fallback
    }

    private func flag(_ key: String, _ fallback: Bool = false) -> Bool {
        properties[key].map { $0 == "true" || $0 == "1" } ?? fallback
    }

    public var targetPlatform: String { properties["project.targetPlatform"] ?? "" }
    public var primaryLanguage: String { properties["project.primaryLanguage"] ?? "" }
    public var defaultThreadID: Int { integer("project.defaultThreadId", 2) }

    public var tags: [Tag] {
        let count = integer("project.tagCount")
        return (0..<max(0, count)).compactMap { index in
            let prefix = "project.tag.\(index)."
            guard let name = properties[prefix + "name"], !name.isEmpty else { return nil }
            return Tag(name: name, type: properties[prefix + "type"] ?? "INT",
                       description: properties[prefix + "desc"] ?? "")
        }
    }

    public var eStop: EStop {
        let ruleCount = integer("project.estop.ruleCount")
        let rules = (0..<max(0, ruleCount)).map { index in
            let prefix = "project.estop.rule.\(index)."
            return EStopRule(channel: properties[prefix + "channel"] ?? "",
                             activeLow: flag(prefix + "activeLow", true),
                             enabled: flag(prefix + "enabled", true),
                             description: properties[prefix + "desc"] ?? "")
        }
        return EStop(enabled: flag("project.estop.enabled"),
                     mode: properties["project.estop.mode"] ?? "",
                     pageName: properties["project.estop.pageName"] ?? "",
                     manualReset: flag("project.estop.manualReset", true),
                     rules: rules)
    }

    public var pageSummaries: [PageSummary] {
        let count = integer("project.pageCount")
        return (0..<max(0, count)).map { index in
            let prefix = "page.\(index)."
            return PageSummary(name: properties[prefix + "name"] ?? "Page \(index + 1)",
                               language: properties[prefix + "language"] ?? "FBD",
                               blocks: integer(prefix + "blockCount"),
                               wires: integer(prefix + "wireCount"),
                               graphics: integer(prefix + "graphicCount"),
                               rungs: integer(prefix + "rungCount"))
        }
    }

    public var graphicCount: Int { pageSummaries.reduce(0) { $0 + $1.graphics } }
    public var wireCount: Int { pageSummaries.reduce(0) { $0 + $1.wires } }

    /// Distinct non-empty bus bundle ids on wires.
    public var busCount: Int {
        var buses: Set<String> = []
        for page in 0..<max(0, integer("project.pageCount")) {
            for wire in 0..<max(0, integer("page.\(page).wireCount")) {
                let id = properties["page.\(page).wire.\(wire).busId"] ?? ""
                if !id.isEmpty { buses.insert(id) }
            }
        }
        return buses.count
    }

    /// Wire bundles grouped by their Maraflow bus id, with their net labels and hidden count.
    public var buses: [BusSummary] {
        struct Group { var wires = 0; var hidden = 0; var names: [String] = [] }
        var groups: [String: Group] = [:]
        for page in 0..<max(0, integer("project.pageCount")) {
            for wire in 0..<max(0, integer("page.\(page).wireCount")) {
                let prefix = "page.\(page).wire.\(wire)."
                guard let id = properties[prefix + "busId"], !id.isEmpty else { continue }
                var group = groups[id] ?? Group()
                group.wires += 1
                if flag(prefix + "hidden") { group.hidden += 1 }
                if let net = properties[prefix + "netName"], !net.isEmpty { group.names.append(net) }
                groups[id] = group
            }
        }
        return groups.keys.sorted().map { id in
            let group = groups[id]!
            return BusSummary(id: id, wireCount: group.wires, hiddenCount: group.hidden,
                              netNames: Array(Set(group.names)).sorted())
        }
    }

    public var hiddenWireCount: Int {
        var hidden = 0
        for page in 0..<max(0, integer("project.pageCount")) {
            for wire in 0..<max(0, integer("page.\(page).wireCount")) {
                if flag("page.\(page).wire.\(wire).hidden") { hidden += 1 }
            }
        }
        return hidden
    }
}
