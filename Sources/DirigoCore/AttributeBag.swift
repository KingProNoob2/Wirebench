import Foundation

/// An ordered, mutable bag of XML attributes.
///
/// Dirigo writes attributes in a stable, meaningful order (it is the order the Delphi
/// `TXMLNode` properties are added in). `Dictionary` loses that order, which makes a
/// byte-faithful re-serialisation of a `.pcc` project impossible and silently reorders
/// attributes every time a project is saved.
///
/// `AttributeBag` keeps insertion order while still offering dictionary-style lookup, so it is
/// a drop-in replacement for the `[String: String]` it replaces: `bag["KEY"]` reads,
/// `bag["KEY"] = v` appends-or-replaces, and `bag.removeValue(forKey:)` deletes.
public struct AttributeBag: Sendable, Equatable {
    private var order: [String]
    private var storage: [String: String]

    public init() {
        self.order = []
        self.storage = [:]
    }

    /// Builds a bag preserving the order of `pairs`. A repeated key keeps its first position
    /// but takes the last value (matching XML semantics for duplicate attributes).
    public init(_ pairs: [(String, String)]) {
        self.order = []
        self.storage = [:]
        self.order.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            if storage[key] == nil { order.append(key) }
            storage[key] = value
        }
    }

    public init(_ dictionary: [String: String]) {
        self.init(dictionary.map { ($0.key, $0.value) })
    }

    /// The attribute names in their original order.
    public var keys: [String] { order }

    public var values: [String] { order.compactMap { storage[$0] } }

    public var count: Int { order.count }

    public var isEmpty: Bool { order.isEmpty }

    /// An unordered view, for code that genuinely wants a dictionary.
    public var dictionary: [String: String] { storage }

    public subscript(key: String) -> String? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { order.append(key) }
                storage[key] = newValue
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /// The value for `key`, or `default` when absent or present-but-empty.
    public func value(for key: String, default fallback: String = "") -> String {
        guard let v = storage[key], !v.isEmpty else { return fallback }
        return v
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> String? {
        guard let existing = storage.removeValue(forKey: key) else { return nil }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        return existing
    }

    public mutating func removeAll() {
        order.removeAll()
        storage.removeAll()
    }

    /// Sets `key` only when it is not already present, appending it at the end.
    public mutating func setIfAbsent(_ key: String, _ value: String) {
        guard storage[key] == nil else { return }
        order.append(key)
        storage[key] = value
    }

    /// Reorders the bag so that the given keys come first, in the given order; anything else
    /// keeps its relative order afterwards. Used to emit modelled attributes in the position
    /// Dirigo itself uses.
    public mutating func moveToFront(_ key: String) {
        guard let idx = order.firstIndex(of: key), idx != 0 else { return }
        order.remove(at: idx)
        order.insert(key, at: 0)
    }
}

extension AttributeBag: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }
}

extension AttributeBag: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: String)> {
        var index = 0
        let keys = order
        let storage = storage
        return AnyIterator {
            while index < keys.count {
                let k = keys[index]
                index += 1
                if let v = storage[k] { return (k, v) }
            }
            return nil
        }
    }
}

extension AttributeBag: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var pairs: [(String, String)] = []
        // Accept both the ordered `[[k, v], ...]` form and a plain JSON object.
        if let single = try? decoder.singleValueContainer(), let dict = try? single.decode([String: String].self) {
            self.init(dict)
            return
        }
        while !container.isAtEnd {
            var inner = try container.nestedUnkeyedContainer()
            let key = try inner.decode(String.self)
            let value = try inner.decode(String.self)
            pairs.append((key, value))
        }
        self.init(pairs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for (key, value) in self {
            var inner = container.nestedUnkeyedContainer()
            try inner.encode(key)
            try inner.encode(value)
        }
    }
}

extension AttributeBag: CustomStringConvertible {
    public var description: String {
        "{" + map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
    }
}

/// Helpers for lifting attributes out of a parsed `XMLDocument` without losing their order.
public enum XMLAttributes {
    /// Every attribute of `element`, in document order, with character references already
    /// decoded by the XML parser.
    public static func bag(of element: XMLElement) -> AttributeBag {
        var pairs: [(String, String)] = []
        for attribute in element.attributes ?? [] {
            if let name = attribute.name, let value = attribute.stringValue {
                pairs.append((name, value))
            }
        }
        return AttributeBag(pairs)
    }
}
