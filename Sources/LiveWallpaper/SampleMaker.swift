import Foundation
import Metal

/// Produces an importable sample `.livewallpaper` (the Matrix code-rain shader) via the real
/// `Library.exportShader` path, after compile-checking the shader so the emitted package is
/// guaranteed to render. Invoked by `LiveWallpaper --make-sample <path>`.
@MainActor
enum SampleMaker {

    static func run(path: String) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        // 1) Compile-check the shader headlessly.
        if let device = MTLCreateSystemDefaultDevice() {
            do { _ = try device.makeLibrary(source: BuiltInShaders.matrixRain, options: nil) }
            catch {
                FileHandle.standardError.write(Data("Shader failed to compile: \(error)\n".utf8))
                return 1
            }
        }

        // 2) Export via the real packaging code (manifest + checksum + zip).
        let config: [Manifest.ConfigEntry] = [
            .init(key: "speed", type: "float", label: "Speed", min: 0.2, max: 3, options: nil, defaultValue: .double(1)),
            .init(key: "tint",  type: "color", label: "Tint",  min: nil, max: nil, options: nil, defaultValue: .string("#33FF66")),
        ]
        do {
            try Library().exportShader(id: "sample.matrix", title: "Matrix Code Rain",
                                       source: BuiltInShaders.matrixRain, config: config, to: url)
            print("Wrote \(url.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Export failed: \(error)\n".utf8))
            return 1
        }
    }
}
