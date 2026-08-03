import AppKit
import SwiftUI

/// The main app window: a sidebar (Installed / Explore / Settings) with a detail pane — the
/// standard "pro" macOS layout. Opened from the menu bar's "Open Primo Engine".
struct MainView: View {
    @ObservedObject var model: AppModel
    /// Bridges the selected section name to the NSWindow title (navigationTitle doesn't reach the
    /// hosted window here; only navigationSubtitle does).
    var onTitle: (String) -> Void = { _ in }
    @State private var section: Section = {
        if let raw = ProcessInfo.processInfo.environment["LW_SECTION"],
           let s = Section(rawValue: raw) { return s }
        return .installed
    }()

    enum Section: String, CaseIterable, Identifiable {
        case installed = "Installed", explore = "Catalog", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .installed: return "square.grid.2x2"
            case .explore: return "square.stack"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
            .safeAreaInset(edge: .bottom) { activeFooter }
        } detail: {
            switch section {
            case .installed: InstalledView(model: model)
            case .explore: ExploreView(model: model)
            case .settings: SettingsTab(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 520)
        .onChange(of: section) { onTitle(section.rawValue) }
        .task { onTitle(section.rawValue) }
        .sheet(item: $model.paywall) { ctx in PaywallSheet(reason: ctx.reason) }
    }

    private var activeFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Now playing").font(.caption2).foregroundStyle(.secondary)
                Text(model.title(forID: model.currentID)).font(.caption.weight(.medium)).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - Shared tile pieces

/// A styled placeholder used when there's no rendered/remote thumbnail (video, web, remote items).
struct PlaceholderThumb: View {
    let seed: String
    let kind: String

    var body: some View {
        ZStack {
            LinearGradient(colors: Self.colors(seed), startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.white.opacity(0.75))
        }
    }
    private var icon: String {
        switch kind { case "video": return "film"; case "web": return "globe"; default: return "sparkles" }
    }
    static func colors(_ s: String) -> [Color] {
        let h = Double(abs(s.hashValue) % 360) / 360.0
        return [Color(hue: h, saturation: 0.55, brightness: 0.55),
                Color(hue: (h + 0.13).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.32)]
    }
}

/// Load a preview thumbnail for an entry: a rendered shader frame, a static video frame, or nil
/// (callers fall back to `PlaceholderThumb`). Shared by every tile so the logic lives in one place.
@MainActor
func loadThumb(_ entry: AppModel.Entry) async -> NSImage? {
    if let src = entry.previewSource { return ThumbnailRenderer.image(forShader: src) }
    if let url = entry.previewVideoURL { return await ThumbnailRenderer.image(forVideoAt: url) }
    return nil
}

/// One wallpaper preview card in the Installed grid.
struct WallpaperTile: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.Entry
    /// The selected monitor from the strip (nil ⇒ act on all displays).
    var target: String? = nil
    /// Open the live preview sheet for this wallpaper (tap the thumbnail).
    var onOpen: (AppModel.Entry) -> Void = { _ in }
    @State private var thumb: NSImage?
    @ObservedObject private var entitlement = Entitlement.shared

    private var isStarred: Bool { model.isStarred(entry.id) }
    private var multiMonitor: Bool { model.screens.count > 1 }
    private var isLocked: Bool { entry.isPremium && !entitlement.isPremium }
    /// Is this wallpaper already applied to whatever "Set" would target?
    private var appliesHere: Bool {
        if let target, let s = model.screens.first(where: { $0.id == target }) { return s.assignedID == entry.id }
        return entry.id == model.currentID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(entry.isBuiltIn ? "built-in · \(entry.kind)" : entry.kind)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if appliesHere {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Set") { applySet() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
                actionsMenu
            }
        }
        .task(id: entry.id) { thumb = await loadThumb(entry) }
    }

    /// The "…" actions menu — always shown: Preview, Apply-to-display (multi-monitor), Share
    /// (imported wallpapers only), Delete (installed only).
    private var actionsMenu: some View {
        Menu {
            Button { onOpen(entry) } label: { Label("Preview", systemImage: "eye") }
            if multiMonitor {
                Menu("Apply to") {
                    Button("All displays") { model.attemptApply(entry) }
                    Divider()
                    ForEach(model.screens) { s in
                        Button(s.name) { model.attemptApply(entry, toScreen: s.id) }
                    }
                }
            }
            if entry.isShareable {
                Button { model.onExport?(entry.id) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            }
            if !entry.isBuiltIn {
                Divider()
                Button(role: .destructive) { model.remove(entry.id) } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private func applySet() { model.attemptApply(entry, toScreen: target) }

    private var preview: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                PlaceholderThumb(seed: entry.title, kind: entry.kind)
            }
        }
        .frame(height: 120).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onOpen(entry) }
        .help("Preview")
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(appliesHere ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .topLeading) {
            if isLocked {
                Label("Premium", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6)).foregroundStyle(.yellow)
                    .clipShape(Capsule()).padding(8)
            } else if appliesHere {
                Text("ACTIVE").font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.9)).foregroundStyle(.white)
                    .clipShape(Capsule()).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { model.toggleStar(entry.id) } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .padding(6).background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isStarred ? .yellow : .white)
            .padding(8)
            .disabled(!isStarred && !model.canStarMore)
            .help(isStarred ? "Unpin from menu bar" : (model.canStarMore ? "Pin to menu bar" : "Menu bar full (\(AppModel.maxStars))"))
        }
    }
}

// MARK: - Live preview

/// Hosts a real renderer (video/metal/web) in a layer-backed view so the preview sheet shows the
/// wallpaper actually running, not a static thumbnail. Starts once the view has a real size and is
/// torn down when the sheet closes.
struct LiveWallpaperView: NSViewRepresentable {
    let makeRenderer: () -> (any WallpaperRenderer)?

    func makeNSView(context: Context) -> RendererHostView {
        let v = RendererHostView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.makeRenderer = makeRenderer
        return v
    }
    func updateNSView(_ nsView: RendererHostView, context: Context) {}
    static func dismantleNSView(_ nsView: RendererHostView, coordinator: ()) { nsView.teardown() }
}

/// Backing view for `LiveWallpaperView`: starts the renderer on first non-zero layout.
final class RendererHostView: NSView {
    var makeRenderer: (() -> (any WallpaperRenderer)?)?
    private var renderer: (any WallpaperRenderer)?
    private var started = false

    override func layout() {
        super.layout()
        guard !started, bounds.width > 1, bounds.height > 1, let layer, let r = makeRenderer?() else { return }
        started = true
        renderer = r
        r.start(in: layer)
        r.resume()
        r.setFrameRate(window?.screen?.maximumFramesPerSecond ?? 60)
    }

    func teardown() { renderer?.stop(); renderer = nil }
}

/// A larger, live preview of one wallpaper with apply + share actions — the "preview before apply"
/// step. Live-renders the wallpaper; applies to all displays or one chosen monitor; shares (P2P).
struct WallpaperPreviewSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.Entry
    var target: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var entitlement = Entitlement.shared

    private var multiMonitor: Bool { model.screens.count > 1 }
    private var isLocked: Bool { entry.isPremium && !entitlement.isPremium }

    var body: some View {
        VStack(spacing: 0) {
            LiveWallpaperView { model.makePreviewRenderer?(entry.id) }
                .frame(width: 660, height: 372)
                .background(Color.black)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text(entry.isBuiltIn ? "built-in · \(entry.kind)" : entry.kind)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.isShareable {
                    Button { model.onExport?(entry.id) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        .help("Export a .livewallpaper to share with someone")
                }
                if isLocked {
                    Button("Unlock Premium") {
                        dismiss()
                        model.showPaywall("“\(entry.title)” is a Premium wallpaper.")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    if multiMonitor {
                        Menu("Apply to…") {
                            Button("All displays") { apply(nil) }
                            Divider()
                            ForEach(model.screens) { s in Button(s.name) { apply(s.id) } }
                        }
                        .fixedSize()
                    }
                    Button("Apply") { apply(target) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 660)
    }

    private func apply(_ key: String?) {
        if let key { model.assign(entry.id, toScreen: key) } else { model.setActive(entry.id) }
        dismiss()
    }
}

// MARK: - Paywall

/// The Premium upsell sheet. Lists what Premium unlocks and offers activation. In this pre-release
/// build the button flips the entitlement locally (see `Entitlement`); real purchase + device-bound
/// licensing land with the backend (docs/LICENSING.md).
struct PaywallSheet: View {
    let reason: String
    @ObservedObject private var entitlement = Entitlement.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint)
                Text("Primo Engine Premium").font(.title2.bold())
            }
            Text(reason).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                benefit("The full wallpaper catalog", "square.stack")
                benefit("Every Metal shader & web wallpaper", "sparkles")
                benefit("Per-display rotation & playlists", "display.2")
                benefit("AI-generated wallpapers (coming soon)", "wand.and.stars")
            }
            Text("One-time purchase · no subscription").font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Pre-release build: this unlocks locally for testing. Real purchase and device-bound licensing arrive with the backend.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Not now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Unlock Premium") { entitlement.unlockForNow(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func benefit(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - AI generation

/// Prompt sheet for AI wallpaper generation. Stays open while generating and dismisses on success;
/// keeps the error visible on failure. Gated to Premium by the caller; needs an API key (Settings).
struct GenerateSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var started = false

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty && AIConfig.isConfigured && !model.isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                Text("Generate a wallpaper").font(.headline)
            }
            Text("Describe a look — we generate a live Metal-shader wallpaper (validated before it's applied).")
                .font(.caption).foregroundStyle(.secondary)

            TextField("e.g. slow aurora over a dark ocean, teal and violet", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)

            if !AIConfig.isConfigured {
                Text("Set up an AI provider in Settings → AI Generation first.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = model.aiError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Generating…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate") { started = true; model.generate(prompt) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canGenerate)
            }
        }
        .padding(20)
        .frame(width: 470)
        // Dismiss once a run we started finishes cleanly; stay open (with the error) on failure.
        .onChange(of: model.isGenerating) {
            if started && !model.isGenerating && model.aiError == nil { dismiss() }
        }
    }
}

// MARK: - Installed

struct InstalledView: View {
    @ObservedObject var model: AppModel
    /// The monitor the plain "Set" button targets (nil ⇒ all displays). Chosen in the strip.
    @State private var target: String?
    /// The wallpaper being previewed in the sheet (nil ⇒ no sheet).
    @State private var preview: AppModel.Entry?
    @State private var showGenerate = false
    @ObservedObject private var entitlement = Entitlement.shared
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 18)]

    /// Ignore a target that points at a display that's no longer connected.
    private var effectiveTarget: String? {
        guard let target, model.screens.contains(where: { $0.id == target }) else { return nil }
        return target
    }
    private var targetName: String {
        model.screens.first(where: { $0.id == effectiveTarget })?.name ?? "All displays"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.screens.count > 1 {
                    MonitorStrip(model: model, target: $target)
                    Text("Setting: \(targetName) — tap a monitor to target it, or use “…” on a wallpaper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.available) {
                        WallpaperTile(model: model, entry: $0, target: effectiveTarget) { preview = $0 }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Installed")
        .navigationSubtitle("\(model.available.count) wallpapers · pin up to \(AppModel.maxStars) ★")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if entitlement.isPremium { showGenerate = true }
                    else { model.showPaywall("AI wallpaper generation is a Premium feature.") }
                } label: { Label("Generate", systemImage: "wand.and.stars") }
                .help("Generate a wallpaper with AI")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.onImport?() } label: { Label("Import", systemImage: "plus") }
                    .help("Import a local .livewallpaper")
            }
        }
        .sheet(item: $preview) { entry in
            WallpaperPreviewSheet(model: model, entry: entry, target: effectiveTarget)
        }
        .sheet(isPresented: $showGenerate) { GenerateSheet(model: model) }
    }
}

// MARK: - Monitor strip (per-display targeting inside Installed)

/// A monitor placed in the strip: its info + the drawn rect (in view points).
struct PlacedScreen: Identifiable {
    let id: String
    let screen: AppModel.ScreenInfo
    let rect: CGRect
}

/// To-scale rects for the connected displays, preserving relative size and layout, fit to a target
/// height. A small gap is carved between adjacent monitors so they read as separate screens.
enum ScreenLayout {
    static func place(_ screens: [AppModel.ScreenInfo], height H: CGFloat, gap: CGFloat = 6) -> [PlacedScreen] {
        guard !screens.isEmpty else { return [] }
        let f = screens.map(\.frame)
        let minX = f.map(\.minX).min()!
        let maxY = f.map(\.maxY).max()!, minY = f.map(\.minY).min()!
        let scale = H / max(maxY - minY, 1)
        return screens.map { s in
            let raw = CGRect(x: (s.frame.minX - minX) * scale,
                             y: (maxY - s.frame.maxY) * scale,   // flip Y (macOS y-up → view y-down)
                             width: s.frame.width * scale, height: s.frame.height * scale)
            return PlacedScreen(id: s.id, screen: s, rect: raw.insetBy(dx: gap / 2, dy: gap / 2))
        }
    }
}

/// Horizontal, scrollable to-scale drawing of the connected monitors, shown at the top of Installed.
/// Each monitor shows a static preview of the wallpaper applied to it + its name; tapping targets it.
struct MonitorStrip: View {
    @ObservedObject var model: AppModel
    @Binding var target: String?
    private let stripHeight: CGFloat = 132

    var body: some View {
        let placed = ScreenLayout.place(model.screens, height: stripHeight)
        let width = placed.map { $0.rect.maxX }.max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(placed) { p in
                    MonitorTile(model: model, screen: p.screen, isSelected: target == p.id)
                        .frame(width: p.rect.width, height: p.rect.height)
                        .offset(x: p.rect.minX, y: p.rect.minY)
                        .onTapGesture { target = (target == p.id ? nil : p.id) }
                }
            }
            .frame(width: max(width, 1), height: stripHeight, alignment: .topLeading)
            .padding(8)
        }
        .frame(height: stripHeight + 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One monitor in the strip: wallpaper preview inside a bezel, name chip, selection ring.
struct MonitorTile: View {
    @ObservedObject var model: AppModel
    let screen: AppModel.ScreenInfo
    let isSelected: Bool
    @State private var thumb: NSImage?

    private var entry: AppModel.Entry? { model.available.first { $0.id == screen.assignedID } }

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                PlaceholderThumb(seed: entry?.title ?? screen.name, kind: entry?.kind ?? "metal")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            Text(screen.name)
                .font(.caption2.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.25),
                    lineWidth: isSelected ? 3 : 1))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .task(id: screen.assignedID) {
            if let e = entry { thumb = await loadThumb(e) } else { thumb = nil }
        }
    }
}

// MARK: - Explore (the workshop)

struct ExploreView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        WorkshopView(
            client: model.workshop,
            onInstall: { item in await model.onInstall?(item) ?? "Install unavailable." },
            screens: model.screens,
            onInstallToScreen: { item, key in await model.onInstallToScreen?(item, key) ?? "Install unavailable." })
        .navigationTitle("Catalog")
    }
}

// MARK: - Settings

/// Provider-agnostic AI settings: pick Anthropic or any OpenAI-compatible endpoint (incl. a local
/// Ollama/LM Studio, which works offline and can't be region-blocked). Keys go to the Keychain.
struct AISettings: View {
    @State private var provider = AIConfig.provider
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        GroupBox("AI Generation") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Provider", selection: $provider) {
                    ForEach(AIConfig.Provider.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: provider) { AIConfig.provider = provider; load() }

                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURL) { AIConfig.setBaseURL(baseURL, for: provider) }
                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { AIConfig.setModel(model, for: provider) }
                SecureField(provider.requiresKey ? "API key" : "API key (optional for local)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { AIConfig.setAPIKey(apiKey.isEmpty ? nil : apiKey, for: provider) }

                Text(provider.hint).font(.caption).foregroundStyle(.secondary)
                Text("Pre-release: the app calls the provider directly with your key (stored in the Keychain). Production will route through our backend, so no key is needed and it works even where a provider is blocked. Premium feature.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
    }

    private func load() {
        baseURL = AIConfig.baseURL(for: provider)
        model = AIConfig.model(for: provider)
        apiKey = AIConfig.apiKey(for: provider) ?? ""
    }
}

struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var entitlement = Entitlement.shared

    // A ScrollView (not a Form) so this tab gets the same large inline title as Installed/Explore.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Premium") {
                    HStack(spacing: 12) {
                        Image(systemName: entitlement.isPremium ? "checkmark.seal.fill" : "sparkles")
                            .font(.title2).foregroundStyle(entitlement.isPremium ? Color.green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entitlement.isPremium ? "Premium active" : "Free")
                                .font(.headline)
                            Text(entitlement.isPremium
                                 ? "The full catalog and all features are unlocked."
                                 : "Unlock the full catalog, per-display rotation, and more.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entitlement.isPremium {
                            Button("Lock (test)") { entitlement.lock() }
                                .help("Developer: relock to test the free experience")
                        } else {
                            Button("Unlock…") { model.showPaywall("Unlock Primo Engine Premium.") }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                        Toggle("Solid backdrop under wallpapers", isOn: $prefs.solidBackdrop)
                        Text("Replaces your macOS desktop picture with a neutral colour so you never see it behind the wallpaper. Your original is restored when you quit or turn this off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                AISettings()
                GroupBox("Power") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("On battery", selection: $prefs.batteryBehavior) {
                            ForEach(BatteryBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Text("Wallpapers always pause when covered, on lock, or when the display sleeps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Rotation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Rotate through all wallpapers", isOn: $prefs.rotationEnabled)
                            .disabled(!entitlement.isPremium)
                        Stepper("Every \(prefs.rotationMinutes) min", value: $prefs.rotationMinutes, in: 1...240)
                            .disabled(!prefs.rotationEnabled || !entitlement.isPremium)
                        if !entitlement.isPremium {
                            Button { model.showPaywall("Rotation is a Premium feature.") } label: {
                                Label("Premium feature — Unlock", systemImage: "lock.fill")
                            }
                            .buttonStyle(.link).font(.caption)
                        } else if model.screens.count > 1 {
                            Text("Each display rotates independently from its current wallpaper.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let schema = model.schemas[model.currentID], !schema.isEmpty {
                    GroupBox("Parameters · \(model.title(forID: model.currentID))") {
                        VStack(alignment: .leading, spacing: 8) {
                            WallpaperParamRows(model: model, schema: schema).id(model.currentID)
                        }
                        .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .navigationSubtitle("Preferences")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    prefs.batteryBehavior = .throttle
                    prefs.rotationEnabled = false
                    prefs.rotationMinutes = 15
                } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .help("Reset preferences to defaults")
            }
        }
    }
}

/// The active wallpaper's parameter controls, backed by a `ConfigStore` recreated per wallpaper.
struct WallpaperParamRows: View {
    @StateObject private var store: ConfigStore

    init(model: AppModel, schema: [ConfigParameter]) {
        let id = model.currentID
        let s = ConfigStore(schema: schema, values: model.configFor?(id) ?? .defaults(for: schema))
        s.onChange = { [weak model] values in model?.onApplyConfig?(id, values) }
        _store = StateObject(wrappedValue: s)
    }

    var body: some View { ConfigControls(store: store) }
}

// MARK: - Window controller

@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: MainView(model: model, onTitle: { [weak self] title in self?.window?.title = title }))
        let w = NSWindow(contentViewController: hosting)
        // Don't set w.title — let each section's SwiftUI navigationTitle drive the title so all
        // three tabs render an identical "Title · Subtitle" header.
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.setContentSize(NSSize(width: 860, height: 560))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
