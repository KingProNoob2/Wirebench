import Foundation

extension PLCProjectCompiler {
    /// Compiled patterns, by pattern text. Compiling is the expensive part of a match, and a build asks for the same
    /// few dozen patterns thousands of times — once per attribute of every module.
    private final class PatternCache: @unchecked Sendable {
        private var compiled: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let known = compiled[pattern] { return known }
            guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
            compiled[pattern] = made
            return made
        }
    }

    private static let patterns = PatternCache()

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = patterns.regex(pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func attribute(_ name: String, _ tag: String) -> String? {
        guard let re = patterns.regex("\\b\(name)=\"([^\"]*)\""),
              let found = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let value = Range(found.range(at: 1), in: tag) else { return nil }
        return String(tag[value])
    }

    /// Each `<MODULE …>` start tag with the text after it, up to the next `</MODULE>` (or to the end of the file
    /// when there is none) — good enough for this file. One pass: a module's body is found from where its tag
    /// matched, not by searching the file for the tag again.
    static func moduleElements(in xml: String) -> [(tag: String, body: String)] {
        guard let re = patterns.regex(#"<MODULE\b[^>]*>"#) else { return [] }
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { found in
            guard let tagRange = Range(found.range, in: xml) else { return nil }
            let rest = xml[tagRange.upperBound...]
            let body = rest.range(of: "</MODULE>").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            return (String(xml[tagRange]), body)
        }
    }
}
