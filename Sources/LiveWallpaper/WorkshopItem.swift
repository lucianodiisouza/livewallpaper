import Foundation

/// One published wallpaper as returned by PocketBase's records API. File fields (`bundle`, `thumb`,
/// `preview`) hold filenames; the public URL is built from the collection + record id + filename.
struct WorkshopItem: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let authorHandle: String?
    let type: WallpaperType
    let tags: [String]
    let checksum: String
    let sizeBytes: Int?
    let downloadCount: Int
    let bundle: String       // filename of the .livewallpaper
    let thumb: String?
    let preview: String?

    enum CodingKeys: String, CodingKey {
        case id, title, type, tags, checksum, bundle, thumb, preview
        case authorHandle = "author_handle"
        case sizeBytes = "size_bytes"
        case downloadCount = "download_count"
    }

    var bundleURL: URL? { fileURL(bundle) }
    var thumbURL: URL? { thumb.flatMap(fileURL) }
    var previewURL: URL? { preview.flatMap(fileURL) }

    private func fileURL(_ filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        return URL(string: "\(WorkshopConfig.pocketBaseURL)/api/files/wallpapers/\(id)/\(filename)")
    }
}
