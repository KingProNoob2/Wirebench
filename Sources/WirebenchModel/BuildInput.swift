import Foundation
import WirebenchCore
import WirebenchLibrary

/// The XML the compiler is given for a project.
///
/// Two things the editor added are not part of Dirigo's file, so neither is in the bytes of a saved `.pcc`: the project's
/// PLC configuration lives in its own section rather than as `SystemCmd` blocks on a sheet, and `If`/`Switch` nesting is
/// recorded as attributes on the container rather than drawn as the marker blocks Dirigo compiles. Both have to be
/// written back out before compiling. The app's *Build* menu and `wirebench-cli build` both come through here, so the two
/// cannot disagree about what a project builds — which they did, because the command line compiled the file as it stood.
public enum BuildInput {
    /// Whether compiling `project` as it stands would build something other than what the editor shows.
    public static func needsPreparation(_ project: PCCProject) -> Bool {
        !project.plcConfiguration.isEmpty || project.modules.contains(where: ConstructContainers.isContainer)
    }

    /// The project as the compiler has to see it: configuration entries back as blocks, containers expanded into Dirigo's
    /// marker blocks.
    public static func prepared(_ project: PCCProject, defaultThread: Int = 2) -> PCCProject {
        ConstructContainers.expanded(PLCConfiguration.injecting(project, defaultThread: defaultThread))
    }

    /// The XML to compile for a project held in memory.
    public static func xml(for project: PCCProject, defaultThread: Int = 2) -> String {
        PCCSerializer().serialize(project: needsPreparation(project) ? prepared(project, defaultThread: defaultThread) : project)
    }

    /// The XML to compile for a project on disk, in either format.
    ///
    /// A legacy file with nothing to prepare is returned exactly as read, so compiling one never depends on this app's
    /// serialiser reproducing the file it was given. The current format is decoded and serialised for the compiler.
    public static func xml(contentsOf url: URL) throws -> String {
        let loaded = try ProjectFile.read(at: url)
        if loaded.format == .dirigo, !needsPreparation(loaded.project) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        return xml(for: loaded.project, defaultThread: configurationThread(of: loaded.project))
    }

    /// Which thread a configuration entry made in the editor runs on: the second one when the profile has two, because
    /// the PLC's commands should run before the circuit does.
    static func configurationThread(of project: PCCProject) -> Int {
        (ProfileRegistry.profile(for: project, in: ProfileRegistry.builtIn)?.threads.count ?? 4) >= 2 ? 2 : 1
    }
}
