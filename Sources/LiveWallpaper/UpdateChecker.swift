import Foundation
import os

/// Lightweight "is there a newer release?" check against the GitHub Releases API. This is the
/// Phase-A bridge until signed builds unlock Sparkle (Phase C): it only *notifies* — it never
/// downloads or installs. When Sparkle lands it takes over and this can be retired.
///
/// No third-party dependency (native URLSession + JSONDecoder), matching the project's rules.
/// Not actor-isolated: pure networking + pure comparison, no shared mutable state beyond a
/// throttle timestamp in UserDefaults.
enum UpdateChecker {

    /// The public repo whose Releases page hosts the builds. Keep in sync with the release workflow.
    static let owner = "lucianodiisouza"
    static let repo = "livewallpaper"

    enum CheckError: LocalizedError {
        case badURL, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad update URL."
            case let .http(code): return "Update check failed (HTTP \(code))."
            }
        }
    }

    /// The subset of a GitHub release record we care about.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let name: String?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name
        }
    }

    struct Outcome: Sendable {
        /// The latest release's version, tag stripped of a leading "v" (e.g. "0.2.0").
        let latestVersion: String
        /// The release page to open for the download.
        let releaseURL: URL
        /// True when `latestVersion` is strictly newer than the running app's version.
        let isNewer: Bool
    }

    /// Ask GitHub for the latest (non-draft, non-prerelease) release and compare it to `currentVersion`.
    /// `/releases/latest` already excludes drafts/prereleases server-side.
    static func fetchLatest(currentVersion: String) async throws -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw CheckError.badURL
        }
        var req = URLRequest(url: url)
        // GitHub rejects API calls without a User-Agent; the Accept header pins the v3 JSON schema.
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PrimoEngine/\(currentVersion) (+https://github.com/\(owner)/\(repo))",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CheckError.http(http.statusCode)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latest = normalized(release.tagName)
        guard let relURL = URL(string: release.htmlURL) else { throw CheckError.badURL }
        return Outcome(latestVersion: latest, releaseURL: relURL,
                       isNewer: isNewer(latest, than: currentVersion))
    }

    // MARK: - Version comparison (pure — exercised by the self-test)

    /// Strip a leading "v"/"V" and any "-suffix" (pre-release/build metadata) from a version string.
    static func normalized(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.drop(while: { $0 == "v" || $0 == "V" })
        return noPrefix.split(separator: "-").first.map(String.init) ?? String(noPrefix)
    }

    /// True iff `candidate` is a strictly newer version than `current`. Compares dot-separated
    /// numeric components (so 0.10.0 > 0.9.0, not the lexical opposite); missing components are 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { normalized(s).split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Auto-check throttle

    private static let lastCheckKey = "updateLastCheck"

    /// Rate-limit the automatic (launch-time) check so we don't hit GitHub every relaunch.
    /// Default: at most once per 24h. The manual "Check for Updates…" path ignores this.
    static func shouldAutoCheck(minInterval: TimeInterval = 24 * 60 * 60) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= minInterval
    }

    static func recordCheck() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }
}

/// `LiveWallpaper --check-updates`: GUI-free version check, mainly for manual/CI verification.
/// Prints current vs latest; exits 0 whether or not an update exists, 1 only on a network error.
enum UpdateCheckSmoke {
    static func run() -> Int32 {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
        final class Box: @unchecked Sendable { var code: Int32 = 0 }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let o = try await UpdateChecker.fetchLatest(currentVersion: current)
                print("current: \(current)  latest: \(o.latestVersion)  → " +
                      (o.isNewer ? "UPDATE AVAILABLE (\(o.releaseURL))" : "up to date"))
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
