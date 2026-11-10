import Foundation
import WirebenchCore
import WirebenchLibrary

/// Editing the project's PLC configuration (`PLCConfiguration`): the commands the PLC is sent, and their parameters.
extension AppModel {
    /// The entries, in the order they are written to the program.
    public var plcCommands: [PCCModule] { project?.plcConfiguration ?? [] }

    private static let profiles = ProfileRegistry.builtIn

    /// The hardware profile the project asks for.
    private var plcProfile: PLCProfile? {
        guard let project else { return nil }
        return ProfileRegistry.profile(for: project, in: Self.profiles)
    }

    /// The thread a new entry runs in: the second (`Tick` in the default profile) where the profile has one, as most projects put it.
    public var configurationThread: Int { (plcProfile?.threads.count ?? 4) >= 2 ? 2 : 1 }

    /// The catalogue variant an entry is: the one its `DEFINITION` names, else the first the profile lists for its command word.
    public func plcCommandInfo(of entry: PCCModule) -> SystemCommandInfo? {
        if let named = systemCommand(of: entry) { return named }
        return systemCommandCatalogue.first { Int($0.command) == entry.plcCommandWord }
    }

    /// The guide for an entry: what its command and parameters are, and the presets for them.
    public func plcGuide(of entry: PCCModule) -> PLCCommandGuide? {
        guard let info = plcCommandInfo(of: entry) else { return nil }
        return PLCCommandGuide.guide(for: info, threads: plcProfile?.threads.map { ($0.name, $0.id) } ?? [])
    }

    /// The hardware profiles, which decide the commands the PLC understands.
    public var plcProfileNames: [String] { Self.profiles.profiles.keys.sorted() }

    /// The profile the project is for.
    public var plcProfileName: String { project?.profile ?? "" }

    /// Makes the project for another hardware profile. The commands in the configuration are kept, even if the new profile does not list them.
    public func setPLCProfile(_ name: String) {
        guard var project, project.profile != name else { return }
        project.profile = name
        commitPLCConfiguration(project)
    }

    /// Adds a command: Configure Pins unless another is given.
    public func addPLCCommand(_ info: SystemCommandInfo? = nil) {
        guard var project else { return }
        let chosen = info ?? systemCommandCatalogue.first { $0.command == 0x0302 }
        project.plcConfiguration.append(PLCConfiguration.newEntry(chosen))
        commitPLCConfiguration(project)
    }

    /// Makes entry `index` send another command.
    public func setPLCCommand(at index: Int, to info: SystemCommandInfo) {
        guard var project, project.plcConfiguration.indices.contains(index) else { return }
        PLCConfiguration.apply(info, to: &project.plcConfiguration[index])
        commitPLCConfiguration(project)
    }

    /// Sets a parameter of entry `index`: `which` is 1 for `Par1`, 2 for `Par2`.
    public func setPLCParameter(at index: Int, _ which: Int, value: Int) {
        guard var project, project.plcConfiguration.indices.contains(index),
              project.plcConfiguration[index].paramPins.indices.contains(which - 1) else { return }
        project.plcConfiguration[index].paramPins[which - 1].value = .int32(Int32(truncatingIfNeeded: value))
        commitPLCConfiguration(project)
    }

    public func removePLCCommand(at index: Int) {
        guard var project, project.plcConfiguration.indices.contains(index) else { return }
        project.plcConfiguration.remove(at: index)
        commitPLCConfiguration(project)
    }

    private func commitPLCConfiguration(_ project: PCCProject) {
        self.project = project
        isDocumentEdited = true
    }
}
