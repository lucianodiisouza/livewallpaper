import Foundation

/// One published wallpaper as returned by the PocketBase `wallpapers` collection. The catalog
/// (metadata) lives in PocketBase on Railway; the actual bundle/preview/thumbnail bytes live in
/// Cloudflare R2 (zero-egress), so each record stores their **full R2 URLs**.
struct WorkshopItem: Codable, Identifiable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case id, title, type, tags, checksum
        case authorHandle = "author_handle"
        case sizeBytes = "size_bytes"
        case downloadCount = "download_count"
        case bundleURLString = "bundle_url"
        case thumbURLString = "thumb_url"
        case previewURLString = "preview_url"
    }

    var bundleURL: URL? { URL(string: bundleURLString) }
    var thumbURL: URL? { thumbURLString.flatMap { URL(string: $0) } }
    var previewURL: URL? { previewURLString.flatMap { URL(string: $0) } }
}
