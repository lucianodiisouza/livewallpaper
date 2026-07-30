import Foundation
import CryptoKit
import os

/// A loaded `.livewallpaper` package on disk (an unpacked directory: `manifest.json` + `content/`).
/// Handles decode, checksum verification, per-type validation, and building the right renderer.
struct WallpaperPackage {

    let directory: URL
    let manifest: Manifest

    private static let log = Logger(subsystem: "com.livewallpaper.app", category: "Package")

    enum PackageError: LocalizedError {
        case missingManifest
        case checksumMismatch
        case missingEntry(String)
        case unsupportedType(WallpaperType)

        var errorDescription: String? {
            switch self {
            case .missingManifest: return "Package has no manifest.json."
            case .checksumMismatch: return "Package checksum does not match its content (possibly corrupt or tampered)."
            case let .missingEntry(e): return "Package entry file '\(e)' is missing."
            case let .unsupportedType(t): return "Wallpaper type '\(t.rawValue)' is not supported yet."
            }
        }
    }

    // MARK: - Loading from an unpacked directory

    /// Load + fully validate a package already unpacked at `directory`.
    static func load(from directory: URL) throws -> WallpaperPackage {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw PackageError.missingManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try manifest.validate()

        let pkg = WallpaperPackage(directory: directory, manifest: manifest)
        try pkg.verify()
        return pkg
    }

    /// Full validation: entry exists, checksum matches, shader passes the safety gate.
    func verify() throws {
        let entryURL = directory.appendingPathComponent(manifest.entry)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw PackageError.missingEntry(manifest.entry)
        }
        if let declared = manifest.checksum {
            let actual = try Self.contentChecksum(in: directory)
            guard declared == actual else {
                Self.log.error("Checksum mismatch: declared \(declared, privacy: .public) actual \(actual, privacy: .public)")
                throw PackageError.checksumMismatch
            }
        }
        if manifest.type == .metal {
            let source = try String(contentsOf: entryURL, encoding: .utf8)
            try ShaderValidator.validate(source)
        }
    }

    // MARK: - Checksum

    /// Canonical checksum over the `content/` payload. Keys are paths **relative to `content/`**;
    /// for each file sorted by that path, hash `<relpath>\0<bytes>`. Result is `sha256-<hex>`.
    /// Shared by the exporter and the verifier so a freshly exported package always verifies.
    static func checksum(ofContentFiles files: [String: Data]) -> String {
        var hasher = SHA256()
        for key in files.keys.sorted() {
            hasher.update(data: Data(key.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: files[key]!)
        }
        return "sha256-" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checksum of the on-disk `content/` directory.
    static func contentChecksum(in directory: URL) throws -> String {
        let contentDir = directory.appendingPathComponent("content")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: contentDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return checksum(ofContentFiles: [:])
        }
        var files: [String: Data] = [:]
        for case let url as URL in en {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let rel = url.path.replacingOccurrences(of: contentDir.path + "/", with: "")
            files[rel] = try Data(contentsOf: url)
        }
        return checksum(ofContentFiles: files)
    }

    // MARK: - Rendering

    /// Build a renderer for this package (video/metal; web arrives in M3).
    @MainActor
    func makeRenderer() throws -> any WallpaperRenderer {
        let entryURL = directory.appendingPathComponent(manifest.entry)
        switch manifest.type {
        case .video:
            return VideoRenderer(url: entryURL)
        case .metal:
            let source = try String(contentsOf: entryURL, encoding: .utf8)
            return MetalRenderer(shaderSource: source, configSchema: manifest.configSchema())
        case .web:
            throw PackageError.unsupportedType(.web)
        }
    }
}
