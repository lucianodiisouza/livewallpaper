import Foundation
import os

/// Generates a self-contained HTML live wallpaper (Canvas/WebGL) from a prompt, via the selected
/// provider. The `WebRenderer` runs the page in a fully caged, offline `WKWebView` — no network, no
/// `file://` — so the generated document must inline everything and reach out to nothing. The result
/// is packaged as a `web` `.livewallpaper` and passes through `WebValidator` before install.
enum WebGenerator {

    private static let log = Logger(subsystem: "com.livewallpaper.app", category: "WebGenerator")

    private static let system = """
    You write self-contained HTML live wallpapers for a locked-down, OFFLINE WKWebView.

    Output ONLY one complete HTML document (`<!doctype html> … </html>`) with ALL CSS and JavaScript \
    inline. No prose, no markdown fences.

    The webview has NO network access and no file access. Therefore:
    - No external resources of any kind: no CDN, no `<script src>`, no `<link href>`, no remote \
      `<img>`, no web fonts, no `fetch`/`XMLHttpRequest`/`WebSocket`, no `eval`.
    - Draw with Canvas 2D or WebGL only, everything computed in-page.

    Requirements: fill 100% of the window (no scrollbars, no margins), a dark background, animate \
    continuously with `requestAnimationFrame`, and handle window resize. No user interaction. Keep \
    it CPU/GPU-light — it runs behind other windows.
    """

    /// Generate HTML for `prompt`. `feedback` (optional) steers a repair attempt.
    static func generate(prompt: String, feedback: String? = nil) async throws -> String {
        var userText = "Create an HTML live wallpaper: \(prompt)"
        if let feedback { userText += "\n\nThe previous attempt failed: \(feedback)\nReturn a corrected, fully-offline HTML document." }

        // A full HTML document (inline CSS + Canvas/WebGL JS) is large; a low cap truncates it mid-JS,
        // producing a broken page that renders black. Give it generous headroom.
        let text = try await AIProviderFactory.current().complete(system: system, user: userText, maxTokens: 16384)
        log.notice("Generated web wallpaper (\(AIConfig.provider.label, privacy: .public)) for prompt (\(prompt.prefix(40), privacy: .public)…)")
        return AIParse.codeBlock(from: text)
    }
}
