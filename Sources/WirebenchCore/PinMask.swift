import Foundation

/// A pin mask as the project file writes it: Delphi hex (`$0473`), or plain decimal.
///
/// `Int("0x0473", radix: 16)` is `nil` — Swift's radix initialiser does not accept a `0x` prefix — so the
/// earlier `"$" → "0x"` rewrite silently read every mask as 0, which showed `8xDO` with all fourteen channels
/// visible and no pin names.
public enum PinMask {
    public static func parse(_ raw: String) -> Int {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("$") { return Int(text.dropFirst(), radix: 16) ?? 0 }
        if text.lowercased().hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) ?? 0 }
        return Int(text) ?? 0
    }
}
