import AppKit
import os

/// The local store of installed `.livewallpaper` packages (unpacked under Application Support), plus
/// per-screen wallpaper assignments. Phase-2's workshop will feed installs through the same
/// `install(fromZipAt:)` entry point.
@MainActor
final class Library {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "Library")
    private let fm = FileManager.default

    /// …/Application Support/LiveWallpaper/Library/<packageID>/
    private let root: URL

    init() {
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        root = appSupport.appendingPathComponent("LiveWallpaper/Library", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Listing

    /// Every installed package that still loads & verifies.
    func installedPackages() -> [WallpaperPackage] {
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            do { return try WallpaperPackage.load(from: dir) }
            catch { log.error("Skipping bad package at \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"); return nil }
        }
    }

    // MARK: - Install

    /// Import a `.livewallpaper` file: extract → validate → verify checksum → store unpacked.
    @discardableResult
    func install(fromZipAt url: URL) throws -> WallpaperPackage {
        let data = try Data(contentsOf: url)
        var files = try ZipArchive.extract(data)

        // Tolerate an archive that wraps everything in a top-level folder (e.g. Finder-made zips).
        files = Self.stripCommonPrefix(files)
        guard let manifestData = files["manifest.json"] else { throw WallpaperPackage.PackageError.missingManifest }

        // Decode + validate the manifest before touching disk.
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        try manifest.validate()

        // Verify checksum against the extracted content/ payload (before install).
        if let declared = manifest.checksum {
            let contentFiles = files
                .filter { $0.key.hasPrefix("content/") }
                .reduce(into: [String: Data]()) { $0[String($1.key.dropFirst("content/".count))] = $1.value }
            guard declared == WallpaperPackage.checksum(ofContentFiles: contentFiles) else {
                throw WallpaperPackage.PackageError.checksumMismatch
            }
        }

        // Write into a fresh folder named by the package id.
        let dest = root.appendingPathComponent(Self.safeName(manifest.id), isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for (rel, bytes) in files {
            let fileURL = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: fileURL)
        }

        // Load from disk so the returned package is exactly what will render (re-runs full verify,
        // including the shader safety gate).
        do {
            let pkg = try WallpaperPackage.load(from: dest)
            log.notice("Installed '\(pkg.manifest.title, privacy: .public)' (\(pkg.manifest.type.rawValue, privacy: .public)).")
            return pkg
        } catch {
            try? fm.removeItem(at: dest)   // don't leave a broken install behind
            throw error
        }
    }

    // MARK: - Export (build a .livewallpaper from a built-in shader)

    /// Package an MSL shader into a stored-only `.livewallpaper` at `destination`.
    func exportShader(id: String, title: String, source: String,
                      config: [Manifest.ConfigEntry], to destination: URL) throws {
        let entryRel = "shader.metal"
        let contentFiles = [entryRel: Data(source.utf8)]
        let checksum = WallpaperPackage.checksum(ofContentFiles: contentFiles)

        let manifest = Manifest(
            schemaVersion: 1, id: id, version: "1.0.0", title: title,
            author: Manifest.Author(id: nil, handle: "built-in"),
            type: .metal, entry: "content/\(entryRel)", minMacOS: "26.0",
            checksum: checksum, config: config,
            capabilities: Manifest.Capabilities(network: [], audio: false))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)

        let archive = ZipArchive.archive([
            "manifest.json": manifestData,
            "content/\(entryRel)": Data(source.utf8),
        ])
        try archive.write(to: destination)
        log.notice("Exported '\(title, privacy: .public)' → \(destination.lastPathComponent, privacy: .public)")
    }

    // MARK: - Per-screen assignments

    /// Which wallpaper id renders on which screen. Ids may be built-ins or package ids.
    private var assignments: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "screenAssignments") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "screenAssignments") }
    }

    func assignedID(for screen: NSScreen, default def: String) -> String {
        assignments[Self.key(for: screen)] ?? UserDefaults.standard.string(forKey: "wallpaperID") ?? def
    }

    func assign(_ id: String, to screen: NSScreen) {
        var a = assignments
        a[Self.key(for: screen)] = id
        assignments = a
    }

    func assignToAll(_ id: String, screens: [NSScreen]) {
        var a = assignments
        for s in screens { a[Self.key(for: s)] = id }
        assignments = a
        UserDefaults.standard.set(id, forKey: "wallpaperID")   // fallback for new screens
    }

    static func key(for screen: NSScreen) -> String {
        let num = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.stringValue
        return num ?? screen.localizedName
    }

    // MARK: - Helpers

    private static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// If every entry shares one top-level folder, strip it (handles Finder/ditto-style zips).
    private static func stripCommonPrefix(_ files: [String: Data]) -> [String: Data] {
        let tops = Set(files.keys.compactMap { $0.split(separator: "/").first.map(String.init) })
        guard tops.count == 1, let top = tops.first,
              files.keys.allSatisfy({ $0.hasPrefix(top + "/") }),
              !files.keys.contains("manifest.json") else { return files }
        return files.reduce(into: [String: Data]()) { $0[String($1.key.dropFirst(top.count + 1))] = $1.value }
    }
}
