import Foundation

/// The wallpaper medium. Mirrors `type` in the `.livewallpaper` manifest (PACKAGE_FORMAT.md).
enum WallpaperType: String, Codable, Sendable {
    case video, metal, web
}

/// Decoded `manifest.json`. Kept deliberately close to the on-disk schema so decode is 1:1.
struct Manifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let version: String
    let title: String
    let author: Author?
    let type: WallpaperType
    let entry: String
    let minMacOS: String?
    let checksum: String?
    let config: [ConfigEntry]?
    let capabilities: Capabilities?

    struct Author: Codable, Sendable {
        let id: String?
        let handle: String?
    }

    struct Capabilities: Codable, Sendable {
        let network: [String]?
        let audio: Bool?
    }

    /// One `config` entry. `default` is a reserved word → mapped via CodingKeys.
    struct ConfigEntry: Codable, Sendable {
        let key: String
        let type: String            // "float" | "int" | "bool" | "color" | "enum"
        let label: String?
        let min: Double?
        let max: Double?
        let options: [String]?
        let defaultValue: Scalar?

        enum CodingKeys: String, CodingKey {
            case key, type, label, min, max, options
            case defaultValue = "default"
        }
    }

    /// A JSON scalar that can be a number, bool, or string (for `default`).
    enum Scalar: Codable, Sendable {
        case double(Double), bool(Bool), string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else { self = .string(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case let .double(d): try c.encode(d)
            case let .bool(b): try c.encode(b)
            case let .string(s): try c.encode(s)
            }
        }
        var double: Double? { if case let .double(d) = self { return d }; return nil }
        var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
        var string: String? { if case let .string(s) = self { return s }; return nil }
    }

    // MARK: - Validation

    enum ValidationError: LocalizedError {
        case unsupportedSchema(Int)
        case emptyField(String)
        case badMinMacOS(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(v): return "Unsupported manifest schemaVersion \(v) (expected 1)."
            case let .emptyField(f): return "Manifest field '\(f)' is missing or empty."
            case let .badMinMacOS(v): return "Wallpaper requires macOS \(v), which is newer than this system."
            }
        }
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw ValidationError.unsupportedSchema(schemaVersion) }
        guard !id.isEmpty else { throw ValidationError.emptyField("id") }
        guard !title.isEmpty else { throw ValidationError.emptyField("title") }
        guard !entry.isEmpty else { throw ValidationError.emptyField("entry") }
        if let min = minMacOS, !Self.systemMeets(minMacOS: min) {
            throw ValidationError.badMinMacOS(min)
        }
    }

    private static func systemMeets(minMacOS: String) -> Bool {
        let parts = minMacOS.split(separator: ".").map { Int($0) ?? 0 }
        let v = OperatingSystemVersion(
            majorVersion: parts.first ?? 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(v)
    }

    /// Map manifest `config` entries to the shared `ConfigParameter` model that drives the settings
    /// UI. Unsupported kinds (int/enum in M2) are dropped for now.
    func configSchema() -> [ConfigParameter] {
        (config ?? []).compactMap { entry in
            let label = entry.label ?? entry.key
            switch entry.type {
            case "float", "int":
                return ConfigParameter(key: entry.key, label: label,
                    kind: .float(min: entry.min ?? 0, max: entry.max ?? 1,
                                 default: entry.defaultValue?.double ?? entry.min ?? 0))
            case "bool":
                return ConfigParameter(key: entry.key, label: label,
                    kind: .bool(default: entry.defaultValue?.bool ?? false))
            case "color":
                return ConfigParameter(key: entry.key, label: label,
                    kind: .color(default: entry.defaultValue?.string ?? "#FFFFFF"))
            default:
                return nil   // enum and unknown kinds: not supported in M2
            }
        }
    }

    /// Inverse of `configSchema()`: turn the shared config model into manifest `config` entries.
    /// Used by the exporter (both the in-app export and the `--export` CLI).
    static func configEntries(from schema: [ConfigParameter]) -> [ConfigEntry] {
        schema.map { p in
            switch p.kind {
            case let .float(min, max, def):
                return ConfigEntry(key: p.key, type: "float", label: p.label,
                                   min: min, max: max, options: nil, defaultValue: .double(def))
            case let .bool(def):
                return ConfigEntry(key: p.key, type: "bool", label: p.label,
                                   min: nil, max: nil, options: nil, defaultValue: .bool(def))
            case let .color(def):
                return ConfigEntry(key: p.key, type: "color", label: p.label,
                                   min: nil, max: nil, options: nil, defaultValue: .string(def))
            }
        }
    }
}
