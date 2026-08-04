import Foundation

/// A `JSONDecoder` configured for the PocketBase wire format: ISO-8601 dates with optional
/// fractional seconds. PocketBase stores every timestamp as UTC; we decode to `Date` directly
/// instead of bouncing through strings in every call site.
extension JSONDecoder {
    static var pocketBase: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            // PocketBase emits "2026-08-04 12:34:56.789Z" (space, not "T"); tolerate both.
            let normalised = s.replacingOccurrences(of: " ", with: "T")
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: normalised) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: normalised) { return d }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                debugDescription: "Unrecognised ISO-8601 date: \(s)")
        }
        return d
    }
}

/// Read-only client for the PocketBase workshop. Browsing needs no auth — the collection's list
/// rule (`status = "published"`) governs visibility server-side. Not actor-isolated: it's pure
/// networking with no shared mutable state.
struct WorkshopClient: Sendable {

    enum Sort: String, Sendable, CaseIterable {
        case newest, popular
        var apiValue: String { self == .newest ? "-created" : "-download_count" }
        var label: String {
            switch self {
            case .newest: return String(localized: "sort.newest")
            case .popular: return String(localized: "sort.popular")
            }
        }
    }

    enum WorkshopError: LocalizedError {
        case notConfigured, badURL, http(Int)
        case premiumBackendUnavailable, premiumLocked
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "The workshop isn't configured yet (set WorkshopConfig.pocketBaseURL)."
            case .badURL: return "Bad workshop URL."
            case let .http(code): return "Workshop request failed (HTTP \(code))."
            case .premiumBackendUnavailable:
                return "This is a Premium wallpaper, but the backend isn't configured (Settings → AI Generation → Backend URL)."
            case .premiumLocked:
                // The backend refused this device (402): either not Premium yet, or Premium was
                // bought but this Mac was never activated (its device id isn't registered).
                return "This wallpaper is Premium. Activate this device (Settings → Premium) to install it."
            }
        }

        /// True for failures that mean "this device can't get this premium bundle." The install path
        /// re-opens the paywall for these instead of showing a passing banner, so a UI that thinks it's
        /// Premium (dev override / stale license) can't diverge silently from the backend's device gate.
        var requiresPaywall: Bool {
            switch self {
            case .premiumLocked, .premiumBackendUnavailable: return true
            case .notConfigured, .badURL, .http: return false
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

    // MARK: - Rotation

    /// A premium wallpaper temporarily free for everyone — including non-Premium members — for a
    /// defined period. Driven by the backoffice: the operator picks N wallpapers + a date range and
    /// the catalog list-rule is bypassed for those checksums during the window. The client just
    /// reads the active set and surfaces it in the UI.
    struct Rotation: Codable, Sendable {
        /// The wallpapers in the active rotation, in display order (operator-defined).
        let items: [WorkshopItem]
        /// When the rotation starts. The list-rule bypass is active from this moment on.
        let startsAt: Date
        /// When the rotation ends — after this, items in `items` are Premium-only again.
        let endsAt: Date
        /// A short headline the operator can override (e.g. "Black Friday picks"). Empty for the
        /// default copy.
        let headline: String
    }

    /// The current rotation, or nil if the backoffice hasn't enabled one / the period has lapsed.
    /// Cached for 5 minutes — rotation is low-frequency, but we want changes to land quickly when
    /// the operator flips a switch.
    func fetchRotation() async -> Rotation? {
        guard WorkshopConfig.isConfigured else { return nil }
        let url = URL(string: "\(WorkshopConfig.pocketBaseURL)/api/collections/rotation/records/active")!
        if let cached = await WorkshopCache.shared.cachedRotation(forKey: url.absoluteString, maxAge: 300) {
            return cached
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            // The active-record endpoint returns 404 when no rotation is configured — that's the
            // happy "rotation is off" path, not an error.
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 { return nil }
            try Self.check(resp)
            let raw = try JSONDecoder.pocketBase.decode(RotationResponse.self, from: data)
            let wallpapers = try await fetchWallpapersByIDs(raw.wallpaperIDs)
            let r = Rotation(items: wallpapers, startsAt: raw.startsAt, endsAt: raw.endsAt, headline: raw.headline ?? "")
            await WorkshopCache.shared.storeRotation(r, forKey: url.absoluteString)
            return r
        } catch {
            return nil
        }
    }

    /// A single record in the PocketBase `rotation` collection.
    private struct RotationResponse: Decodable {
        let startsAt: Date
        let endsAt: Date
        let headline: String?
        let wallpaperIDs: [String]

        enum CodingKeys: String, CodingKey {
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case headline
            case wallpaperIDs = "wallpaper_ids"
        }
    }

    /// Hydrate a set of wallpaper ids into full `WorkshopItem` records. The backoffice stores
    /// wallpaper ids (stable per docs/PACKAGE_FORMAT.md) so a rotation entry survives an
    /// editor-side title change.
    private func fetchWallpapersByIDs(_ ids: [String]) async throws -> [WorkshopItem] {
        guard !ids.isEmpty else { return [] }
        guard var comps = URLComponents(string: "\(WorkshopConfig.pocketBaseURL)/api/collections/wallpapers/records") else {
            throw WorkshopError.badURL
        }
        // PocketBase's `id` filter is `id='…' || id='…'`. We cap to 200 ids per call (the existing
        // catalog fetch also tops out at 200); the backoffice's "items per rotation" UI should
        // keep it well under that.
        let filter = ids.prefix(200).map { "id='\($0)'" }.joined(separator: " || ")
        comps.queryItems = [
            URLQueryItem(name: "perPage", value: "200"),
            URLQueryItem(name: "filter", value: filter),
        ]
        guard let url = comps.url else { throw WorkshopError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        try Self.check(resp)
        return try JSONDecoder().decode(PBList.self, from: data).items
    }

    /// Download a bundle to a temp `.livewallpaper` file (then hand to `Library.install`). Content is
    /// cached by checksum, so a repeat install of the same wallpaper re-downloads nothing; the caller
    /// re-verifies the checksum regardless, so a cache hit is never trusted on faith.
    ///
    /// Free items come straight from their public R2 URL. Premium items are **device-bound**: their
    /// bytes live in a private bucket and are streamed by the backend `/catalog/bundle` route only to
    /// devices whose premium flag is set (see the Worker + docs/LICENSING.md).
    func downloadBundle(_ item: WorkshopItem) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).livewallpaper")
        try? FileManager.default.removeItem(at: dest)

        if let cached = await WorkshopCache.shared.cachedBundle(forChecksum: item.checksum) {
            try FileManager.default.copyItem(at: cached, to: dest)
            return dest
        }

        if item.isPremium {
            try await downloadPremiumBundle(item, to: dest)
        } else {
            guard let src = item.bundleURL else { throw WorkshopError.badURL }
            let (tmp, resp) = try await URLSession.shared.download(from: src)
            try Self.check(resp)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        await WorkshopCache.shared.storeBundle(from: dest, checksum: item.checksum)
        return dest
    }

    /// Build the device-gated POST for a premium bundle. Pure + side-effect-free so it can be unit
    /// tested; returns nil if the backend base URL or the item's bundle key is missing.
    static func premiumBundleRequest(backendBase: String, deviceID: String, item: WorkshopItem) -> URLRequest? {
        let base = backendBase.hasSuffix("/") ? String(backendBase.dropLast()) : backendBase
        guard !base.isEmpty, let key = item.bundleKey, !key.isEmpty,
              let url = URL(string: base + "/catalog/bundle") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": deviceID, "item_id": item.id, "bundle_key": key,
        ])
        return req
    }

    /// Stream a premium bundle from the backend to `dest`. A 402 means this device isn't entitled —
    /// surfaced as a friendly "unlock Premium" message rather than a raw HTTP error.
    private func downloadPremiumBundle(_ item: WorkshopItem, to dest: URL) async throws {
        guard let req = Self.premiumBundleRequest(
            backendBase: AIConfig.backendURL, deviceID: Device.id, item: item)
        else { throw WorkshopError.premiumBackendUnavailable }

        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 402 { throw WorkshopError.premiumLocked }
        try Self.check(resp)
        try FileManager.default.moveItem(at: tmp, to: dest)
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
