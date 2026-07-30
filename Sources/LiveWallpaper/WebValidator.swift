import Foundation
import os

/// Static import-time scan for web wallpapers. Unlike the shader gate (which *rejects*), this only
/// **flags** — the real containment is enforced at runtime by WebRenderer (no file://, network
/// blocked except the manifest allowlist, navigation blocked). These warnings are logged for
/// visibility now and become moderation signals in Phase 2.
enum WebValidator {

    private static let log = Logger(subsystem: "com.livewallpaper.app", category: "WebValidator")

    private static let patterns: [(needle: String, note: String)] = [
        ("fetch(", "uses fetch()"),
        ("XMLHttpRequest", "uses XMLHttpRequest"),
        ("WebSocket", "opens a WebSocket"),
        ("EventSource", "uses server-sent events"),
        ("importScripts", "uses importScripts"),
        ("http://", "references an http:// URL"),
        ("https://", "references an https:// URL"),
        ("eval(", "uses eval()"),
        ("new Function(", "builds code with new Function()"),
        ("atob(", "decodes base64 (possible obfuscation)"),
    ]

    static func warnings(source: String, filename: String) -> [String] {
        patterns.filter { source.contains($0.needle) }.map { "\(filename): \($0.note)" }
    }

    /// Walk a package's `content/` tree and flag concerns in html/js/css files.
    static func scan(directory: URL) -> [String] {
        let content = directory.appendingPathComponent("content")
        guard let en = FileManager.default.enumerator(at: content, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in en {
            guard ["html", "htm", "js", "mjs", "css"].contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out += warnings(source: text, filename: url.lastPathComponent)
        }
        if !out.isEmpty {
            log.notice("Web wallpaper flags: \(out.joined(separator: "; "), privacy: .public)")
        }
        return out
    }
}
