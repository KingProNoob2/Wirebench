import Foundation
import DirigoCore
import DirigoLibrary

/// Choosing which command a `SystemCmd` block sends: the variants `Profiles.ini` lists for the project's hardware.
extension AppModel {
    /// The commands the project's profile supports, by display text.
    public var systemCommandCatalogue: [SystemCommandInfo] {
        guard let database = ProfileRegistry.load() else { return [] }
        let profile = project.flatMap { database.profile(named: $0.profile) } ?? database.defaultProfile
        guard let profile else { return [] }
        return database.systemCommands(for: profile).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// The variant a module is set to, matched to the catalogue by command word and label.
    public func systemCommand(of module: PCCModule) -> SystemCommandInfo? {
        guard let definition = module.rawAttributes["DEFINITION"].flatMap(ProfilesParser.systemCommand(fromDefinition:)) else { return nil }
        return systemCommandCatalogue.first { $0.command == definition.command && $0.text == definition.text } ?? definition
    }

    /// Gives a `SystemCmd` block a command — its `DEFINITION`, its command word on the `Cmd` pin, and so its pin
    /// names and the words the compiler writes — or returns it to the plain block with `nil`.
    public func setSystemCommand(moduleId: Int, to info: SystemCommandInfo?) {
        guard var project, let index = project.modules.firstIndex(where: { $0.id == moduleId }) else { return }
        if let info {
            project.modules[index].rawAttributes["DEFINITION"] = info.definitionString
            if project.modules[index].inPins.count > 1 {
                project.modules[index].inPins[1].value = .int32(Int32(info.command))
            }
        } else {
            project.modules[index].rawAttributes["DEFINITION"] = nil
        }
        self.project = project
        runtimeDidChangeStructure()
    }
}
