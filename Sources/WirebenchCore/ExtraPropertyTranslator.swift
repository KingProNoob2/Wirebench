import Foundation

/// What happens to an extra property that no declaration covers.
public enum ExtraPropertyExportPolicy: Sendable {
    /// Remove it and report. The default, because compatibility is the point of exporting: an
    /// attribute nobody has agreed on is one the original is entitled to ignore or misread.
    case drop
    /// Leave it in the file, trusting Dirigo to ignore what it does not model.
    case keep
}

public struct ExtraPropertyExportResult: Sendable {
    public let project: PCCProject
    /// One line per extra property touched, ready to show the user.
    public let notes: [String]
}

/// Turns this app's extra properties into things the original Dirigo understands.
///
/// This runs on **export only**. A normal save keeps every `X_` attribute, so improvements made here
/// survive editing; export is the boundary where the project has to become something Dirigo can
/// read. Each extra property is handled according to its declaration:
///
/// * `dirigoAttribute(name, transform:)` — the value moves into an attribute Dirigo already has;
/// * `drop` — it is removed, because there is no counterpart to move it to;
/// * `keep` — it is left alone;
/// * anything undeclared falls to `defaultPolicy`.
///
/// Nothing is ever written for a transform that returns `nil`: that means the value has no
/// counterpart for *that* value, and dropping it beats writing something wrong.
public enum ExtraPropertyTranslator {

    /// Translates every extra property in `project`.
    ///
    /// - Parameter declarations: extra properties by block GUID. Keying on the GUID rather than the
    ///   block's name means the mapping survives an instance being renamed, and keeps this file in
    ///   `WirebenchCore` — the catalog that knows GUID-to-type lives a layer above.
    public static func translate(
        _ project: PCCProject,
        declarations: [UUID: [ExtraPropertyDeclaration]] = [:],
        defaultPolicy: ExtraPropertyExportPolicy = .drop
    ) -> ExtraPropertyExportResult {
        var output = project
        var notes: [String] = []

        for index in output.modules.indices {
            var module = output.modules[index]
            let names = module.extraPropertyNames
            guard !names.isEmpty else { continue }

            let declared = declarations[module.guid] ?? []
            for name in names {
                let key = PCCModule.extraPropertyPrefix + name
                guard let text = module.rawAttributes[key] else { continue }
                let value = ExtraPropertyValue.decode(text)

                guard let declaration = declared.first(where: { $0.name == name }) else {
                    switch defaultPolicy {
                    case .keep:
                        notes.append("\(module.name): kept \(name) (undeclared)")
                    case .drop:
                        module.rawAttributes.removeValue(forKey: key)
                        notes.append("\(module.name): removed \(name) — no Dirigo counterpart")
                    }
                    continue
                }

                switch declaration.counterpart {
                case .keep:
                    notes.append("\(module.name): kept \(name)")

                case .drop:
                    module.rawAttributes.removeValue(forKey: key)
                    notes.append("\(module.name): removed \(name) — no Dirigo counterpart")

                case .dirigoAttribute(let target, let transform):
                    guard let encoded = transform(declaration.type.coerce(value)) else {
                        module.rawAttributes.removeValue(forKey: key)
                        notes.append("\(module.name): removed \(name) — its value has no Dirigo equivalent")
                        continue
                    }
                    let replaced = module.rawAttributes[target] != nil
                    module.rawAttributes[target] = encoded
                    module.rawAttributes.removeValue(forKey: key)
                    notes.append("\(module.name): \(name) → \(target)"
                                 + (replaced ? " (replaced the existing \(target))" : ""))
                }
            }
            output.modules[index] = module
        }

        return ExtraPropertyExportResult(project: output, notes: notes)
    }
}
