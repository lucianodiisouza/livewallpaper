import Foundation

/// Read-only client for the PocketBase workshop. Browsing needs no auth — the collection's list
/// rule (`status = "published"`) governs visibility server-side. Not actor-isolated: it's pure
/// networking with no shared mutable state.
struct WorkshopClient: Sendable {

    enum Sort: String, Sendable, CaseIterable {
        case newest, popular
        var apiValue: String { self == .newest ? "-created" : "-download_count" }
        var label: String { self == .newest ? "Newest" : "Popular" }
    }

    enum WorkshopError: LocalizedError {
        case notConfigured, badURL, http(Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "The workshop isn't configured yet (set WorkshopConfig.pocketBaseURL)."
            case .badURL: return "Bad workshop URL."
            case let .http(code): return "Workshop request failed (HTTP \(code))."
            }
        }
    }

    private struct PBList: Decodable { let items: [WorkshopItem] }

    /// Browse/search published wallpapers.
    func fetchCatalog(search: String = "", sort: Sort = .newest) async throws -> [WorkshopItem] {
        guard WorkshopConfig.isConfigured else { throw WorkshopError.notConfigured }
        guard var comps = URLComponents(string: "\(WorkshopConfig.pocketBaseURL)/api/collections/wallpapers/records")
        else { throw WorkshopError.badURL }

        var filter = "status='published'"
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            filter += " && title~'\(term.replacingOccurrences(of: "'", with: ""))'"
        }
        comps.queryItems = [
            URLQueryItem(name: "perPage", value: "200"),
            URLQueryItem(name: "sort", value: sort.apiValue),
            URLQueryItem(name: "filter", value: filter),
        ]
        guard let url = comps.url else { throw WorkshopError.badURL }

        // Collapse the burst of identical fetches (load → sort toggle → post-install reload) into one
        // Railway hit. Short TTL: freshness of the listing still matters more than saving a request.
        let key = url.absoluteString
        if let cached = await WorkshopCache.shared.cachedCatalog(forKey: key, maxAge: Self.catalogTTL) {
            return cached
        }

        let (data, resp) = try await URLSession.shared.data(from: url)
        try Self.check(resp)
        let items = try JSONDecoder().decode(PBList.self, from: data).items
        await WorkshopCache.shared.storeCatalog(items, forKey: key)
        return items
    }

    /// How long a fetched catalog stays servable from the memo before we re-hit Railway.
    private static let catalogTTL: TimeInterval = 60

    /// Download a bundle to a temp `.livewallpaper` file (then hand to `Library.install`). Content is
    /// cached by checksum, so a repeat install of the same wallpaper re-downloads nothing; the caller
    /// re-verifies the checksum regardless, so a cache hit is never trusted on faith.
    func downloadBundle(_ item: WorkshopItem) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).livewallpaper")
        try? FileManager.default.removeItem(at: dest)

        if let cached = await WorkshopCache.shared.cachedBundle(forChecksum: item.checksum) {
            try FileManager.default.copyItem(at: cached, to: dest)
            return dest
        }

        guard let src = item.bundleURL else { throw WorkshopError.badURL }
        let (tmp, resp) = try await URLSession.shared.download(from: src)
        try Self.check(resp)
        try FileManager.default.moveItem(at: tmp, to: dest)
        await WorkshopCache.shared.storeBundle(from: dest, checksum: item.checksum)
        return dest
    }

    /// Best-effort download counter. Requires a small PocketBase hook route (see M4_PLAN §5);
    /// silently no-ops if the route isn't installed.
    func incrementDownload(_ id: String) async {
        guard WorkshopConfig.isConfigured,
              let url = URL(string: "\(WorkshopConfig.pocketBaseURL)/api/lw/increment/\(id)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    private static func check(_ resp: URLResponse) throws {
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WorkshopError.http(http.statusCode)
        }
    }
}

/// `LiveWallpaper --workshop-smoke`: fetch the catalog and print the count. GUI-free check for the
/// networking layer (needs a configured, reachable PocketBase to return data).
enum WorkshopSmoke {
    static func run() -> Int32 {
        guard WorkshopConfig.isConfigured else {
            print("Workshop not configured — set WorkshopConfig.pocketBaseURL. (Expected before provisioning.)")
            return 0
        }
        final class Box: @unchecked Sendable { var code: Int32 = 0 }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let items = try await WorkshopClient().fetchCatalog()
                print("OK: \(items.count) published wallpaper(s).")
            } catch {
                print("ERROR: \(error.localizedDescription)")
                box.code = 1
            }
            sem.signal()
        }
        sem.wait()
        return box.code
    }
}
