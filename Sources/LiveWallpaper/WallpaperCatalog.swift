import Foundation

/// The built-in wallpapers you can switch between from the menu bar. In M2 this list is joined by
/// installed `.livewallpaper` packages from the local library; the menu/rendering path is the same.
@MainActor
enum WallpaperCatalog {

    struct Item: Identifiable {
        let id: String
        let title: String
        let kind: String            // "video" | "metal" | "web"
        let make: () -> WallpaperRenderer
    }

    /// Shared parameter schema for the demo shaders — drives the auto-generated settings panel.
    static let shaderConfig: [ConfigParameter] = [
        ConfigParameter(key: "speed", label: "Speed", kind: .float(min: 0.1, max: 3.0, default: 1.0)),
        ConfigParameter(key: "tint",  label: "Tint",  kind: .color(default: "#FFFFFF")),
    ]

    static let all: [Item] = [
        Item(id: "video",  title: "Video Loop", kind: "video") { VideoRenderer() },
        Item(id: "plasma", title: "Shader · Plasma", kind: "metal") {
            MetalRenderer(shaderSource: BuiltInShaders.plasma, configSchema: shaderConfig)
        },
        Item(id: "aurora", title: "Shader · Aurora", kind: "metal") {
            MetalRenderer(shaderSource: BuiltInShaders.aurora, configSchema: shaderConfig)
        },
        Item(id: "web-stars", title: "Web · Starfield", kind: "web") {
            WebRenderer(inlineHTML: BuiltInWeb.starfield, allowlist: [], schema: [])
        },
    ]

    static func kind(forID id: String) -> String { all.first { $0.id == id }?.kind ?? "metal" }

    static let defaultID = "plasma"

    static func item(id: String) -> Item {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID } ?? all[0]
    }
}
