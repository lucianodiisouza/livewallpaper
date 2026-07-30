import Foundation
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

    /// `--export <id> <path>`
    static func export(id: String, path: String) -> Int32 {
        guard let sample = samples[id] else {
            FileHandle.standardError.write(Data("Unknown sample '\(id)'. Known: \(samples.keys.sorted().joined(separator: ", "))\n".utf8))
            return 2
        }
        return write(id: id, title: sample.title, source: sample.source, path: path)
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
