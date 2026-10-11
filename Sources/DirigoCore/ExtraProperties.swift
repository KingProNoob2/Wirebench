import Foundation

/// A property this reimplementation carries that the original Dirigo has no concept of.
///
/// The point of these is to let a block *work better here* without giving up compatibility: the
/// value lives in the `.pcc` beside the attributes Dirigo already understands, so a project saved
/// by this app keeps its improvements, and `ExtraPropertyTranslator` turns each one into a Dirigo
/// counterpart (or removes it) on export.
///
/// They are stored as ordinary XML attributes prefixed `X_`, which means:
///
/// * nothing has to change in the parser or the serializer — `PCCModule.rawAttributes` already
///   preserves every attribute it does not model, so extras survive a byte-identical round-trip;
/// * a project with no extras serialises to exactly the same bytes as before, which keeps the
///   whole existing corpus byte-identical;
/// * the original Dirigo sees an attribute it does not use. It may keep it or drop it, but it can
///   always read the file, which is the property that matters.
public enum ExtraPropertyValue: Equatable, Sendable, CustomStringConvertible {
    case int(Int32)
    case double(Double)
    case bool(Bool)
    case string(String)

    /// The attribute text. Integers stay integers so a value never gains a stray `.0`.
    public var encoded: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let v): return v == v.rounded() ? String(Int64(v)) : String(v)
        case .bool(let v): return v ? "true" : "false"
        case .string(let v): return v
        }
    }

    public var description: String { encoded }

    public var intValue: Int32? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int32(exactly: v.rounded())
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Int32(v)
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Double(v)
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .int(let v): return v != 0
        case .double(let v): return v != 0
        case .bool(let v): return v
        case .string(let v):
            switch v.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
    }

    /// Recovers a value from attribute text without a declaration to guide it.
    ///
    /// `1500` reads back as an integer and `12.5` as a double, so an undeclared extra keeps the
    /// type it was written with instead of turning into a string on the next save.
    public static func decode(_ text: String) -> ExtraPropertyValue {
        if let i = Int32(text) { return .int(i) }
        if let d = Double(text) { return .double(d) }
        switch text.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .string(text)
        }
    }
}

/// The types an extra property may declare. Declaring one fixes how its text is read back, so a
/// value like `"0755"` or `"1e3"` cannot drift into a different type across saves.
public enum ExtraPropertyType: String, Sendable, CaseIterable {
    case int, double, bool, string

    /// The declared type's default, used when a module has no stored value for the property.
    public func coerce(_ value: ExtraPropertyValue) -> ExtraPropertyValue {
        switch self {
        case .int: return .int(value.intValue ?? 0)
        case .double: return .double(value.doubleValue ?? 0)
        case .bool: return .bool(value.boolValue ?? false)
        case .string: return .string(value.encoded)
        }
    }
}

/// Where an extra property goes when the project is handed back to the original Dirigo.
public enum ExtraPropertyCounterpart: Sendable {
    /// Write the value into an attribute Dirigo already understands, and drop the `X_` attribute.
    ///
    /// The transform is where a unit or representation change belongs — milliseconds here becoming
    /// seconds there, a mode name becoming the integer Dirigo stores, and so on. Returning `nil`
    /// means "this value has no counterpart after all", and the export reports it as dropped rather
    /// than writing something wrong.
    case dirigoAttribute(String, transform: @Sendable (ExtraPropertyValue) -> String?)

    /// No Dirigo equivalent: remove it on export and say so.
    case drop

    /// Leave it in the file. Dirigo ignores attributes it does not model, so this is the right
    /// choice when a value is genuinely harmless — but it is not the default, because "harmless"
    /// is a claim about someone else's parser.
    case keep

    /// The straightforward case: the value transfers unchanged to an attribute of the same meaning.
    public static func dirigoAttribute(_ name: String) -> ExtraPropertyCounterpart {
        .dirigoAttribute(name, transform: { $0.encoded })
    }
}

/// One extra property a block type may carry, and what becomes of it on export.
public struct ExtraPropertyDeclaration: Sendable, Identifiable {
    public let name: String
    public let type: ExtraPropertyType
    public let defaultValue: ExtraPropertyValue
    public let counterpart: ExtraPropertyCounterpart
    /// Shown to the user, and in the export report.
    public let summary: String

    public var id: String { name }

    public init(name: String,
                type: ExtraPropertyType,
                defaultValue: ExtraPropertyValue,
                counterpart: ExtraPropertyCounterpart,
                summary: String) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.counterpart = counterpart
        self.summary = summary
    }
}

public extension PCCModule {
    /// The attribute prefix that marks a property as belonging to this reimplementation.
    static let extraPropertyPrefix = "X_"

    /// Every extra property on this module, in the order the attributes appear.
    ///
    /// The name is the attribute without its prefix, so `X_RampTime` reads as `RampTime`.
    var extraProperties: [String: ExtraPropertyValue] {
        var found: [String: ExtraPropertyValue] = [:]
        for key in rawAttributes.keys where key.hasPrefix(Self.extraPropertyPrefix) {
            guard let text = rawAttributes[key] else { continue }
            found[String(key.dropFirst(Self.extraPropertyPrefix.count))] = .decode(text)
        }
        return found
    }

    /// The extra property names in attribute order, so a UI can list them deterministically.
    var extraPropertyNames: [String] {
        rawAttributes.keys
            .filter { $0.hasPrefix(Self.extraPropertyPrefix) }
            .map { String($0.dropFirst(Self.extraPropertyPrefix.count)) }
    }

    /// Reads one extra property, applying a declaration's type when there is one.
    func extraProperty(_ name: String, as declaration: ExtraPropertyDeclaration? = nil) -> ExtraPropertyValue? {
        guard let text = rawAttributes[Self.extraPropertyPrefix + name] else { return nil }
        let value = ExtraPropertyValue.decode(text)
        return declaration.map { $0.type.coerce(value) } ?? value
    }

    /// Sets or removes an extra property.
    ///
    /// The attribute is appended when new, which keeps existing attribute order — and therefore the
    /// byte-identical round-trip — intact for everything already in the file.
    mutating func setExtraProperty(_ name: String, _ value: ExtraPropertyValue?) {
        let key = Self.extraPropertyPrefix + name
        if let value {
            rawAttributes[key] = value.encoded
        } else {
            rawAttributes.removeValue(forKey: key)
        }
    }
}
