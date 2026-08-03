import Foundation

/// One published wallpaper as returned by the PocketBase `wallpapers` collection. The catalog
/// (metadata) lives in PocketBase on Railway; the actual bundle/preview/thumbnail bytes live in
/// Cloudflare R2 (zero-egress), so each record stores their **full R2 URLs**.
struct WorkshopItem: Codable, Identifiable, Sendable {
    /// Whether a catalog item is free (public R2 URL) or Premium (device-bound, streamed by the
    /// backend from a private bucket). Unknown/missing values decode as `.free` so older records and
    /// a not-yet-migrated collection keep working.
    enum Tier: String, Codable, Sendable {
        case free, premium
        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Tier(rawValue: raw) ?? .free
        }
    }

    let id: String
    let title: String
    let authorHandle: String?
    let type: WallpaperType
    let tags: [String]
    let checksum: String
    let sizeBytes: Int?
    let downloadCount: Int
    let bundleURLString: String
    let thumbURLString: String?
    let previewURLString: String?
    /// Free vs Premium. Defaults to `.free` when the field is absent.
    let tier: Tier
    /// The R2 object key for a Premium bundle (e.g. `premium/aurora.livewallpaper`). Public URL is
    /// left empty for Premium items; delivery goes through the backend `/catalog/bundle` route.
    let bundleKey: String?

    enum CodingKeys: String, CodingKey {
        case id, title, type, tags, checksum, tier
        case authorHandle = "author_handle"
        case sizeBytes = "size_bytes"
        case downloadCount = "download_count"
        case bundleURLString = "bundle_url"
        case thumbURLString = "thumb_url"
        case previewURLString = "preview_url"
        case bundleKey = "bundle_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        type = try c.decode(WallpaperType.self, forKey: .type)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        checksum = try c.decode(String.self, forKey: .checksum)
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes)
        downloadCount = (try? c.decode(Int.self, forKey: .downloadCount)) ?? 0
        bundleURLString = (try? c.decode(String.self, forKey: .bundleURLString)) ?? ""
        thumbURLString = try c.decodeIfPresent(String.self, forKey: .thumbURLString)
        previewURLString = try c.decodeIfPresent(String.self, forKey: .previewURLString)
        tier = (try? c.decode(Tier.self, forKey: .tier)) ?? .free
        bundleKey = try c.decodeIfPresent(String.self, forKey: .bundleKey)
    }

    var isPremium: Bool { tier == .premium }
    var bundleURL: URL? { URL(string: bundleURLString) }
    var thumbURL: URL? { thumbURLString.flatMap { URL(string: $0) } }
    var previewURL: URL? { previewURLString.flatMap { URL(string: $0) } }
}
