import Foundation

/// The built-in wallpapers you can switch between from the menu bar. In M2 this list is joined by
/// installed `.livewallpaper` packages from the local library; the menu/rendering path is the same.
@MainActor
enum WallpaperCatalog {

    struct Item: Identifiable {
        let id: String
        let title: String
        let kind: String            // "video" | "metal" | "web"
        var isPremium: Bool = false // locked behind the Premium entitlement
        let make: () -> WallpaperRenderer
    }

    /// Shared parameter schema for the demo shaders — drives the auto-generated settings panel.
    static let shaderConfig: [ConfigParameter] = [
        ConfigParameter(key: "speed", label: "Speed", kind: .float(min: 0.1, max: 3.0, default: 1.0)),
        ConfigParameter(key: "tint",  label: "Tint",  kind: .color(default: "#FFFFFF")),
    ]

    static let all: [Item] = [
        // Free sampler: the default wallpaper is always free so free users can render something.
        Item(id: "video",  title: "Video Loop", kind: "video") { VideoRenderer() },
        Item(id: "plasma", title: "Shader · Plasma", kind: "metal") {
            MetalRenderer(shaderSource: BuiltInShaders.plasma, configSchema: shaderConfig)
        },
        // Premium sampler.
        Item(id: "aurora", title: "Shader · Aurora", kind: "metal", isPremium: true) {
            MetalRenderer(shaderSource: BuiltInShaders.aurora, configSchema: shaderConfig)
        },
        Item(id: "web-stars", title: "Web · Starfield", kind: "web", isPremium: true) {
            WebRenderer(inlineHTML: BuiltInWeb.starfield, allowlist: [], schema: [])
        },
    ]

    static func isPremium(forID id: String) -> Bool { all.first { $0.id == id }?.isPremium ?? false }

    static func kind(forID id: String) -> String { all.first { $0.id == id }?.kind ?? "metal" }

    /// Shader source for a built-in metal wallpaper (for preview thumbnails); nil for video/web.
    static func shaderSource(forID id: String) -> String? {
        switch id {
        case "plasma": return BuiltInShaders.plasma
        case "aurora": return BuiltInShaders.aurora
        default: return nil
        }
    }

    static let defaultID = "plasma"

    static func item(id: String) -> Item {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID } ?? all[0]
    }
}
