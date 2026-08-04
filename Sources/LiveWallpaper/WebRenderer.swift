import AppKit
import WebKit
import os

/// Serves a wallpaper's local files to WebKit over a private `lwp://` scheme, scoped to a single
/// root (a package's web directory, or an in-memory set for built-ins). Using a custom scheme means
/// **no `file://` access** — the web content can only reach the bytes we hand it.
final class WebSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {

    private let root: URL?
    private let inline: [String: Data]

    init(diskRoot: URL) { self.root = diskRoot; self.inline = [:] }
    init(inline: [String: Data]) { self.root = nil; self.inline = inline }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        // lwp://wallpaper/<path>   (empty path → index.html)
        var path = task.request.url?.path ?? "/"
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }

        guard let data = data(for: path) else {
            task.didFailWithError(NSError(domain: "lwp", code: 404))
            return
        }
        let resp = URLResponse(url: task.request.url!, mimeType: Self.mime(for: path),
                               expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func data(for path: String) -> Data? {
        if let root {
            // Confine strictly to the root directory (reject traversal).
            let fileURL = root.appendingPathComponent(path).standardizedFileURL
            guard fileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
                    || fileURL.path == root.standardizedFileURL.appendingPathComponent(path).path else { return nil }
            guard fileURL.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
            return try? Data(contentsOf: fileURL)
        }
        return inline[path]
    }

    private static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp4", "m4v": return "video/mp4"
        case "wasm": return "application/wasm"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

/// Renders a web wallpaper (Canvas/WebGL/Three.js) in a locked-down `WKWebView`:
/// - content served over `lwp://` — no `file://`, no local-file escape
/// - **all network blocked** except hosts in the manifest allowlist (WKContentRuleList)
/// - ephemeral data store (no cookies/localStorage persistence)
/// - top-level navigation cancelled; media-capture permission denied
///
/// See DESIGN.md §7 / SECURITY.md. Pausing is best-effort for web (WebKit throttles hidden content).
@MainActor
final class WebRenderer: NSObject, WallpaperRenderer, NowPlayingSink, WKNavigationDelegate, WKUIDelegate {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "WebRenderer")

    let configSchema: [ConfigParameter]
    private let handler: WebSchemeHandler
    private let allowlist: [String]
    private let entryPath: String
    /// Whether this wallpaper opted into now-playing (manifest `capabilities.nowPlaying`). Gates
    /// whether we feed it the user's listening data + album art at all.
    let nowPlayingEnabled: Bool
    private var configJSON = "{}"
    /// Last payload we pushed, replayed once the page finishes loading so a wallpaper that starts
    /// while music is already playing shows the current track immediately.
    private var lastNowPlayingJSON: String?

    private var webView: WKWebView?
    private weak var hostView: NSView?

    /// Disk-backed (a package's web directory).
    init(diskRoot: URL, entry: String, allowlist: [String], schema: [ConfigParameter],
         nowPlaying: Bool = false) {
        self.handler = WebSchemeHandler(diskRoot: diskRoot)
        self.entryPath = entry
        self.allowlist = allowlist
        self.configSchema = schema
        self.nowPlayingEnabled = nowPlaying
    }

    /// Built-in / in-memory (a single index.html).
    init(inlineHTML: String, allowlist: [String], schema: [ConfigParameter],
         nowPlaying: Bool = false) {
        self.handler = WebSchemeHandler(inline: ["index.html": Data(inlineHTML.utf8)])
        self.entryPath = "index.html"
        self.allowlist = allowlist
        self.configSchema = schema
        self.nowPlayingEnabled = nowPlaying
    }

    func start(in layer: CALayer) {
        hostView = layer.delegate as? NSView
        Task { @MainActor in
            let rules = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "lw-net",
                                        encodedContentRuleList: Self.ruleJSON(allowlist: allowlist))
            self.finishStart(rules: rules)
        }
    }

    private func finishStart(rules: WKContentRuleList?) {
        guard let hostView else { log.error("No host view for web wallpaper."); return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(handler, forURLScheme: "lwp")
        if let rules { config.userContentController.add(rules) }

        // Expose config to the page before its own scripts run.
        let inject = WKUserScript(
            source: "window.LiveWallpaper=window.LiveWallpaper||{};window.LiveWallpaper.config=\(configJSON);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(inject)

        let web = WKWebView(frame: hostView.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // transparent over the black host layer
        hostView.addSubview(web)
        self.webView = web

        if let url = URL(string: "lwp://wallpaper/\(entryPath)") {
            web.load(URLRequest(url: url))
        }
        log.notice("Web wallpaper started (allowlist: \(self.allowlist.isEmpty ? "none" : self.allowlist.joined(separator: ","), privacy: .public)).")
    }

    // MARK: - WallpaperRenderer

    /// Hiding the web view blanks it to the black host layer. Doing that the instant occlusion flips
    /// makes switching macOS Spaces flash black-then-content, because a Space transition toggles
    /// `occlusionState` off→on within a few hundred ms. So defer the actual hide: suspend media at
    /// once (invisible, saves work), but only blank the view if it stays covered past this grace
    /// window. A resume that lands first cancels it — no flash. Genuine long occlusion still hides
    /// and drops to ~0% GPU.
    private var pendingHide: DispatchWorkItem?
    private static let hideGrace: TimeInterval = 0.75

    func pause() {
        webView?.setAllMediaPlaybackSuspended(true)
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.webView?.isHidden = true }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideGrace, execute: work)
    }
    func resume() {
        pendingHide?.cancel(); pendingHide = nil
        webView?.isHidden = false
        webView?.setAllMediaPlaybackSuspended(false)
    }
    func setFrameRate(_ fps: Int) { /* not controllable for web; occlusion pause is the lever */ }

    func apply(config values: [String: ConfigValue]) {
        configJSON = Self.json(from: values)
        webView?.evaluateJavaScript(
            "window.LiveWallpaper&&(window.LiveWallpaper.config=\(configJSON),window.LiveWallpaper.onConfig&&window.LiveWallpaper.onConfig(window.LiveWallpaper.config));",
            completionHandler: nil)
    }

    func stop() {
        pendingHide?.cancel(); pendingHide = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - NowPlayingSink

    var acceptsNowPlaying: Bool { nowPlayingEnabled }

    /// Push a now-playing payload into the page, mirroring how `config` is delivered: set the field
    /// and invoke the page's `onNowPlaying` hook if it registered one.
    func updateNowPlaying(json: String) {
        guard nowPlayingEnabled else { return }
        lastNowPlayingJSON = json
        webView?.evaluateJavaScript(
            "window.LiveWallpaper&&(window.LiveWallpaper.nowPlaying=\(json),window.LiveWallpaper.onNowPlaying&&window.LiveWallpaper.onNowPlaying(window.LiveWallpaper.nowPlaying));",
            completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate (block top-level navigation away from our content)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "lwp" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Replay the current track once the page is ready (it may have loaded mid-song).
        if let json = lastNowPlayingJSON { updateNowPlaying(json: json) }
    }

    // MARK: - WKUIDelegate (deny camera/mic)

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: - Helpers

    /// Content-rule JSON: block everything, then allow our own scheme + any allowlisted hosts.
    static func ruleJSON(allowlist: [String]) -> String {
        var rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^lwp://"},"action":{"type":"ignore-previous-rules"}}
        """
        for host in allowlist {
            let safe = host.replacingOccurrences(of: "\"", with: "")
            rules += ",{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*\(safe)\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}"
        }
        rules += "]"
        return rules
    }

    static func json(from values: [String: ConfigValue]) -> String {
        var parts: [String] = []
        for key in values.keys.sorted() {
            switch values[key]! {
            case let .float(v): parts.append("\"\(key)\":\(v)")
            case let .bool(v): parts.append("\"\(key)\":\(v)")
            case let .color(v): parts.append("\"\(key)\":\"\(v)\"")
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
