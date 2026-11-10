import Foundation
import WirebenchCore
import WirebenchLibrary

/// The project's PLC configuration: what used to be `SystemCmd` blocks on a sheet, held as a list of commands instead.
///
/// A `SystemCmd` block sends one command to the PLC's firmware — in nearly every project the same one, *Configure Pins* (`0x0302`, `Par1 = 112`),
/// with constant inputs and an output nobody reads — so a block on the sheet was the wrong place for it: it is a setting of the PLC, not a part of
/// the circuit. Here each is an entry in the project (`PCCProject.plcConfiguration`) that the *PLC Configuration* menu edits.
///
/// An entry **is** the block (a `PCCModule`), kept off the sheet. That is what makes the round trip exact: loading a legacy `.pcc` moves each
/// qualifying block into the list as it is, and the block that *Export Legacy .PCC* and *Build* put back is that same block — its page, place, order,
/// thread, pin display formats and all — so the file Dirigo reads and the program the compiler writes are what they were.
///
/// Only a block that is plain configuration moves: a constant command and constant parameters, enabled, and nothing wired to or from it. One that is
/// wired (a `Pwm` whose value comes from the circuit, a command whose answer is used) is part of the circuit, and stays a block.
public enum PLCConfiguration {
    /// Whether a block is only configuration, and so becomes an entry.
    public static func isConfiguration(_ module: PCCModule, in project: PCCProject) -> Bool {
        guard module.guid == SystemCmdBlock.guid,
              module.inPins.count == 2, module.paramPins.count == 2, module.outPins.count == 1,
              module.inPins[0].value.asBool else { return false }
        return !(project.inConnections + project.paramConnections).contains { $0.inModuleId == module.id || $0.outModuleId == module.id }
    }

    /// The project with its configuration blocks moved off the sheets into `plcConfiguration`, in the order they were in the file.
    ///
    /// Each entry remembers where in the file's list of blocks it stood (`positionKey`), because that order is observable: the symbol table writes
    /// its rows block by block in file order, so a block put back elsewhere would reorder them.
    public static func extracting(_ project: PCCProject) -> PCCProject {
        var output = project
        var moved: [PCCModule] = []
        for (index, module) in project.modules.enumerated() where isConfiguration(module, in: project) {
            var entry = module
            entry.rawAttributes[positionKey] = String(index)
            moved.append(entry)
        }
        guard !moved.isEmpty else { return project }
        let ids = Set(moved.map(\.id))
        output.modules.removeAll { ids.contains($0.id) }
        output.plcConfiguration += moved
        return output
    }

    /// The attribute an entry carries for its place in the file's list of blocks. It belongs to the configuration and is never written on a block.
    public static let positionKey = "PLC_POSITION"

    /// The project with its configuration written back as blocks on the sheets: what the original Dirigo reads, and what the compiler builds the
    /// PLC program from. An entry from a file goes back where it was; one made in the editor gets a place — the first sheet that is not a macro,
    /// below the blocks there, early in the thread, so that it runs before the circuit does.
    public static func injecting(_ project: PCCProject, defaultThread: Int = 2) -> PCCProject {
        guard !project.plcConfiguration.isEmpty else { return project }
        var output = project
        output.plcConfiguration = []
        var used = Set(output.modules.map(\.id))
        var next = (used.max() ?? 0) + 1
        // In the order they stood in the file, so that putting each back at its place restores the list.
        let entries = project.plcConfiguration.sorted {
            ($0.rawAttributes[positionKey].flatMap { Int($0) } ?? Int.max) < ($1.rawAttributes[positionKey].flatMap { Int($0) } ?? Int.max)
        }
        for var entry in entries {
            if entry.page.isEmpty {
                entry.page = output.pages.first { !$0.caption.hasPrefix("*") }?.caption ?? output.pages.first?.caption ?? "main"
                entry.threadId = defaultThread
                let onPage = output.modules.filter { $0.page == entry.page }
                entry.x = onPage.map(\.x).min() ?? 20
                entry.y = (onPage.map { $0.y + Double(CardGeometry.dirigoExtent(for: $0).height) }.max() ?? 0) + 40
                entry.order = max(1, (output.modules.filter { $0.threadId == defaultThread }.map(\.order).min() ?? 20) - 10)
                entry.name = BlockFactory.suggestedName(for: SystemCmdBlock.guid, existing: output.modules)
            }
            if entry.id <= 0 || used.contains(entry.id) {
                entry.id = next
            }
            used.insert(entry.id)
            next = max(next, entry.id + 1)
            if let position = entry.rawAttributes.removeValue(forKey: positionKey).flatMap({ Int($0) }) {
                output.modules.insert(entry, at: min(max(position, 0), output.modules.count))
            } else {
                output.modules.append(entry)
            }
        }
        return output
    }

    /// A new entry: the block a person would add, set to `command` (Configure Pins unless said otherwise), not yet placed on any sheet.
    public static func newEntry(_ command: SystemCommandInfo?) -> PCCModule {
        var entry = BlockFactory.makeModule(guid: SystemCmdBlock.guid, id: 0, name: "SystemCmd", x: 0, y: 0, order: 0, threadId: 0, page: "")
        if let command { apply(command, to: &entry) }
        return entry
    }

    /// Gives an entry its command: the variant (`DEFINITION`) that names its parameters, and its command word.
    public static func apply(_ info: SystemCommandInfo?, to entry: inout PCCModule) {
        if let info {
            entry.rawAttributes["DEFINITION"] = info.definitionString
            if entry.inPins.count > 1 { entry.inPins[1].value = .int32(Int32(info.command)) }
        } else {
            entry.rawAttributes["DEFINITION"] = nil
        }
    }
}

extension PCCModule {
    /// The command word an entry sends (the block's `Cmd` input).
    public var plcCommandWord: Int { inPins.count > 1 ? inPins[1].value.asInt : 0 }
    /// A parameter of the command: `1` is `Par1`, `2` is `Par2`.
    public func plcParameter(_ which: Int) -> Int { paramPins.indices.contains(which - 1) ? paramPins[which - 1].value.asInt : 0 }
}
