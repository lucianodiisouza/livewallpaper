import Foundation

/// A user-tweakable parameter a wallpaper exposes. In M1 these are declared in code by the
/// built-in wallpapers; in M2 they'll be decoded from `manifest.config` (see PACKAGE_FORMAT.md) —
/// the model is shared so the auto-generated settings panel works the same either way.
struct ConfigParameter: Identifiable, Sendable {
    let key: String
    let label: String
    let kind: Kind

    var id: String { key }

    enum Kind: Sendable {
        case float(min: Double, max: Double, `default`: Double)
        case bool(default: Bool)
        case color(default: String)   // hex "#RRGGBB"
    }

    var defaultValue: ConfigValue {
        switch kind {
        case let .float(_, _, d): return .float(d)
        case let .bool(d):        return .bool(d)
        case let .color(d):       return .color(d)
        }
    }
}

/// A concrete value for a `ConfigParameter`.
enum ConfigValue: Equatable, Sendable {
    case float(Double)
    case bool(Bool)
    case color(String)   // hex "#RRGGBB"

    var asDouble: Double? { if case let .float(v) = self { return v }; return nil }
    var asBool: Bool? { if case let .bool(v) = self { return v }; return nil }
    var asHex: String? { if case let .color(v) = self { return v }; return nil }
}

extension Dictionary where Key == String, Value == ConfigValue {
    /// Seed a value map from a schema's defaults.
    static func defaults(for schema: [ConfigParameter]) -> [String: ConfigValue] {
        Dictionary(uniqueKeysWithValues: schema.map { ($0.key, $0.defaultValue) })
    }
}
