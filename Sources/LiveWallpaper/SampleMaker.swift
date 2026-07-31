import Foundation
import AppKit
import Metal

/// Exports built-in shaders to `.livewallpaper` packages via the real `Library.exportShader` path,
/// compile-checking the shader first so the emitted package is guaranteed to render. Used to seed
/// the workshop (`--export <id> <path>`) and for import testing (`--make-sample <path>`).
@MainActor
enum SampleMaker {

    struct Sample { let title: String; let source: String }

    static let samples: [String: Sample] = [
        "plasma": Sample(title: "Plasma", source: BuiltInShaders.plasma),
        "aurora": Sample(title: "Aurora", source: BuiltInShaders.aurora),
        "matrix": Sample(title: "Matrix Code Rain", source: BuiltInShaders.matrixRain),
        "rings": Sample(title: "Rings", source: BuiltInShaders.rings),
        "interference": Sample(title: "Interference", source: BuiltInShaders.interference),
        "spiral": Sample(title: "Spiral", source: BuiltInShaders.spiral),
        "tunnel": Sample(title: "Tunnel", source: BuiltInShaders.tunnel),
        "cells": Sample(title: "Cells", source: BuiltInShaders.cells),
    ]

    /// Phase-2 workshop inventory (astro / topographic / dev / electronic). Exportable via
    /// `--export-batch <dir>`, but intentionally not in `samples` and not in `WallpaperCatalog.all` —
    /// the goal is to ship them as ready-to-publish packages without bloating the in-app menu.
    static let workshop: [String: Sample] = [
        "nebula-orion":        Sample(title: "Nebula · Orion",        source: MoreShaders.nebulaOrion),
        "nebula-milky-way":    Sample(title: "Nebula · Milky Way",    source: MoreShaders.nebulaMilkyWay),
        "planet-jupiter":      Sample(title: "Planet · Jupiter",      source: MoreShaders.planetJupiter),
        "planet-saturn":       Sample(title: "Planet · Saturn",       source: MoreShaders.planetSaturn),
        "topo-contours":       Sample(title: "Topo · Contours",       source: MoreShaders.topoContours),
        "topo-isometric":      Sample(title: "Topo · Isometric",      source: MoreShaders.topoIsometric),
        "dev-syntax":          Sample(title: "Dev · Soft Syntax",     source: MoreShaders.devSyntax),
        "dev-git-graph":       Sample(title: "Dev · Git Graph",       source: MoreShaders.devGitGraph),
        "dev-terminal":        Sample(title: "Dev · Terminal",        source: MoreShaders.devTerminal),
        "elec-pcb":            Sample(title: "Electronic · PCB",      source: MoreShaders.elecPCB),
        "elec-resistor":       Sample(title: "Electronic · Resistor", source: MoreShaders.elecResistor),
        "elec-oscilloscope":   Sample(title: "Electronic · Scope",    source: MoreShaders.elecOscilloscope),
    ]

    /// `--export <id> <path>`
    static func export(id: String, path: String) -> Int32 {
        let all = samples.merging(workshop) { _, new in new }
        guard let sample = all[id] else {
            FileHandle.standardError.write(Data("Unknown sample '\(id)'. Known: \(all.keys.sorted().joined(separator: ", "))\n".utf8))
            return 2
        }
        return write(id: id, title: sample.title, source: sample.source, path: path)
    }

    /// `--export-batch <dir>` — write every workshop sample as a `.livewallpaper` package into `dir`.
    /// Used to seed the workshop catalog with the new astro / topo / dev / electronic shaders.
    static func batchExport(dir: String) -> Int32 {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("mkdir \(url.path) failed: \(error)\n".utf8))
            return 1
        }
        var failed = 0
        for (id, sample) in workshop.sorted(by: { $0.key < $1.key }) {
            let out = url.appendingPathComponent("\(id).livewallpaper")
            let rc = write(id: id, title: sample.title, source: sample.source, path: out.path)
            if rc != 0 { failed += 1 }
        }
        let total = workshop.count
        print("exported \(total - failed)/\(total) packages → \(url.path)")
        return failed == 0 ? 0 : 1
    }

    /// `--render-thumbs <in-dir> <out-dir>` — for every `*.livewallpaper` in `in-dir`, read its
    /// `content/shader.metal` and write a 1024×N PNG to `out-dir/<id>.png`. Used to populate the
    /// workshop grid with previews so the catalog looks alive even before users install anything.
    static func renderThumbs(inDir: String, outDir: String, size: CGSize = CGSize(width: 1024, height: 640)) -> Int32 {
        let inURL = URL(fileURLWithPath: (inDir as NSString).expandingTildeInPath)
        let outURL = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("mkdir \(outURL.path) failed: \(error)\n".utf8))
            return 1
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: inURL, includingPropertiesForKeys: nil) else {
            FileHandle.standardError.write(Data("cannot list \(inURL.path)\n".utf8))
            return 1
        }
        let pkgs = files.filter { $0.pathExtension == "livewallpaper" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if pkgs.isEmpty {
            FileHandle.standardError.write(Data("no .livewallpaper files in \(inURL.path)\n".utf8))
            return 1
        }
        var failed = 0
        for url in pkgs {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let files = try ZipArchive.extract(data)
                guard let shader = files["content/shader.metal"].flatMap({ String(data: $0, encoding: .utf8) }) else {
                    throw NSError(domain: "thumbs", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing content/shader.metal"])
                }
                // Compile-check via MetalLibrary compile path before rendering.
                if let device = MTLCreateSystemDefaultDevice() {
                    _ = try device.makeLibrary(source: shader, options: nil)
                }
                guard let img = ThumbnailRenderer.image(forShader: shader, size: size, time: 4.0) else {
                    throw NSError(domain: "thumbs", code: 2, userInfo: [NSLocalizedDescriptionKey: "thumbnail render returned nil"])
                }
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "thumbs", code: 3, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
                }
                let out = outURL.appendingPathComponent("\(id).png")
                try png.write(to: out)
                print("  • \(id).png")
            } catch {
                FileHandle.standardError.write(Data("  ✗ \(id): \(error.localizedDescription)\n".utf8))
                failed += 1
            }
        }
        print("rendered \(pkgs.count - failed)/\(pkgs.count) thumbnails → \(outURL.path)")
        return failed == 0 ? 0 : 1
    }

    /// `--make-sample <path>` (the Matrix rain — kept for quick import testing).
    static func run(path: String) -> Int32 {
        let m = samples["matrix"]!
        return write(id: "matrix", title: m.title, source: m.source, path: path)
    }

    private static func write(id: String, title: String, source: String, path: String) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        if let device = MTLCreateSystemDefaultDevice() {
            do { _ = try device.makeLibrary(source: source, options: nil) }
            catch {
                FileHandle.standardError.write(Data("Shader failed to compile: \(error)\n".utf8))
                return 1
            }
        }
        do {
            try Library().exportShader(id: "builtin.\(id)", title: title, source: source,
                                       config: Manifest.configEntries(from: WallpaperCatalog.shaderConfig),
                                       to: url)
            print("Wrote \(url.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Export failed: \(error)\n".utf8))
            return 1
        }
    }
}
