import AppKit
import CryptoKit
import os

/// Client-side cache for workshop content, sized to cut *backend* load rather than to be complete:
/// every read here is a request that never reaches Railway (catalog) or R2 (thumbnails, bundles).
///
/// Three tiers, in descending request frequency:
///  - **thumbnails** — memory (NSCache) + disk; the Explore grid would otherwise refetch on every
///    scroll/redraw. This is the bulk of R2 Class-B operations.
///  - **catalog** — short-TTL in-memory memo keyed by the exact request URL; collapses the burst of
///    identical fetches from load → sort toggle → post-install reload into one Railway hit.
///  - **bundles** — content-addressed on disk by the package checksum. A repeat install of the same
///    wallpaper re-downloads nothing; `Library.install` re-verifies the checksum regardless, so a
///    cached bundle is never trusted on the strength of being cached.
///
/// Everything lives under `Caches/` so the OS can evict it under disk pressure and it stays out of
/// backups. An actor because it owns the disk layout and the catalog memo; the NSCache is itself
/// thread-safe but is fine to touch from within.
actor WorkshopCache {
    static let shared = WorkshopCache()

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "WorkshopCache")
    private let fm = FileManager.default

    private let thumbsDir: URL
    private let bundlesDir: URL

    /// Decoded catalogs by request URL, with the time they were fetched. Cleared on process exit —
    /// freshness matters more than persistence for the listing.
    private var catalogMemo: [String: (at: Date, items: [WorkshopItem])] = [:]

    /// In-memory thumbnails. Bounded by count *and* rough byte cost so a long scroll can't grow it
    /// without bound; the disk copy backs anything the OS evicts here.
    private let thumbMemory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        c.totalCostLimit = 64 * 1024 * 1024   // ~64 MB of decoded images
        return c
    }()

    private init() {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let root = caches.appendingPathComponent("LiveWallpaper/Workshop", isDirectory: true)
        thumbsDir = root.appendingPathComponent("thumbs", isDirectory: true)
        bundlesDir = root.appendingPathComponent("bundles", isDirectory: true)
        for dir in [thumbsDir, bundlesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Catalog

    /// A still-fresh cached catalog for this request URL, or nil if absent/stale.
    func cachedCatalog(forKey key: String, maxAge: TimeInterval) -> [WorkshopItem]? {
        guard let hit = catalogMemo[key], Date().timeIntervalSince(hit.at) < maxAge else { return nil }
        return hit.items
    }

    func storeCatalog(_ items: [WorkshopItem], forKey key: String) {
        catalogMemo[key] = (Date(), items)
    }

    // MARK: - Rotation

    /// Memo of active rotations by request URL. Same shape as the catalog memo — short TTL
    /// because the operator's switch in the backoffice should land within minutes, not hours.
    private var rotationMemo: [String: (at: Date, value: WorkshopClient.Rotation)] = [:]

    func cachedRotation(forKey key: String, maxAge: TimeInterval) -> WorkshopClient.Rotation? {
        guard let hit = rotationMemo[key], Date().timeIntervalSince(hit.at) < maxAge else { return nil }
        return hit.value
    }

    func storeRotation(_ r: WorkshopClient.Rotation, forKey key: String) {
        rotationMemo[key] = (Date(), r)
    }

    // MARK: - Bundles

    /// Path a bundle with this checksum would occupy on disk, whether or not it exists.
    private func bundlePath(forChecksum checksum: String) -> URL {
        bundlesDir.appendingPathComponent("\(Self.slug(checksum)).livewallpaper")
    }

    /// The cached bundle for this checksum, or nil on a miss. `nil` checksum (unsigned package)
    /// never caches — there's no safe content-addressed key for it.
    func cachedBundle(forChecksum checksum: String?) -> URL? {
        guard let checksum else { return nil }
        let path = bundlePath(forChecksum: checksum)
        return fm.fileExists(atPath: path.path) ? path : nil
    }

    /// Copy a freshly downloaded bundle into the cache under its checksum. Best-effort: a failure to
    /// cache is never fatal to the install that produced the file.
    func storeBundle(from tmp: URL, checksum: String?) {
        guard let checksum else { return }
        let dest = bundlePath(forChecksum: checksum)
        guard !fm.fileExists(atPath: dest.path) else { return }
        do { try fm.copyItem(at: tmp, to: dest) }
        catch { log.debug("bundle cache store failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Thumbnails

    /// A thumbnail image for this item, served from memory → disk → network in that order. Returns
    /// nil only if the item has no thumbnail URL or the fetch fails.
    func thumbnail(for item: WorkshopItem) async -> NSImage? {
        guard let url = item.thumbURL else { return nil }
        let key = Self.slug(url.absoluteString)

        if let img = thumbMemory.object(forKey: key as NSString) { return img }

        let diskURL = thumbsDir.appendingPathComponent(key)
        if let data = try? Data(contentsOf: diskURL), let img = NSImage(data: data) {
            thumbMemory.setObject(img, forKey: key as NSString, cost: data.count)
            return img
        }

        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let img = NSImage(data: data) else { return nil }
            try? data.write(to: diskURL, options: .atomic)
            thumbMemory.setObject(img, forKey: key as NSString, cost: data.count)
            return img
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// A filesystem-safe, collision-resistant filename derived from an arbitrary string.
    private static func slug(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
