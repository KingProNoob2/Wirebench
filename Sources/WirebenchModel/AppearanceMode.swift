import Foundation

/// The app's light/dark choice. `system` follows the platform; the others override it.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
