import AppKit
import SwiftUI

/// The main app window: a glass top-nav bar (Installed / Explore / Settings) over a full-width
/// detail pane — a more modern layout than the old sidebar. Opened from the menu bar's
/// "Open Primo Engine". Each section's `.toolbar` items still land in the window titlebar, so the
/// per-section actions (Generate/Import, Reset) are unchanged.
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
        // A NavigationStack so each section's `.navigationTitle`/`.toolbar` still populate the
        // window titlebar exactly as they did under the old NavigationSplitView detail pane.
        NavigationStack {
            Group {
                switch section {
                case .installed: InstalledView(model: model)
                case .explore: ExploreView(model: model)
                case .settings: SettingsTab(model: model)
                }
            }
            // The nav floats as a top safe-area inset so each section's scroll content passes *under*
            // the glass — that's what makes the Liquid Glass actually refract (like an iPad tab bar).
            .safeAreaInset(edge: .top, spacing: 0) {
                TopNav(section: $section, model: model)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .onChange(of: section) { onTitle(section.rawValue) }
        .task { onTitle(section.rawValue) }
        .sheet(item: $model.paywall) { ctx in PaywallSheet(reason: ctx.reason) }
    }
}

/// The top navigation bar: a floating, centered Liquid Glass segmented control (macOS 26), like the
/// tab bar on iPadOS. The three sections live in one continuous glass block; the selection is a
/// tinted glass pill that morphs across it. A compact "Now playing" glass chip floats at the trailing
/// edge as an overlay so it never shifts the centered group.
struct TopNav: View {
    @Binding var section: MainView.Section
    @ObservedObject var model: AppModel
    @Namespace private var glass

    var body: some View {
        segmentedControl
            .frame(maxWidth: .infinity)                 // center the segmented control
            .overlay(alignment: .trailing) { nowPlaying }
            .padding(.horizontal, 16)
            .padding(.top, 10).padding(.bottom, 12)
    }

    /// One continuous glass capsule holding the three tabs, with a single tinted-glass pill sliding
    /// behind the selected one (morphed via `glassEffectID` inside the shared container).
    private var segmentedControl: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(MainView.Section.allCases) { tab($0) }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func tab(_ s: MainView.Section) -> some View {
        let selected = section == s
        return Button {
            withAnimation(.smooth(duration: 0.28)) { section = s }
        } label: {
            Label(s.rawValue, systemImage: s.icon)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .contentShape(.capsule)
                // The moving selection: only the active tab carries glass, and it shares one
                // `glassEffectID`, so it morphs from tab to tab inside the container above.
                .background {
                    if selected {
                        Color.clear
                            .glassEffect(.regular.tint(.accentColor.opacity(0.22)).interactive(),
                                         in: .capsule)
                            .glassEffectID("selection", in: glass)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(s.rawValue)
    }

    private var nowPlaying: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary)
            Text(model.title(forID: model.currentID))
                .font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .help("Now playing")
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
    @State private var showCustomize = false
    @ObservedObject private var entitlement = Entitlement.shared

    private var isStarred: Bool { model.isStarred(entry.id) }
    /// This wallpaper exposes tweakable parameters ⇒ it can be customized.
    private var isCustomizable: Bool { !(model.schemas[entry.id] ?? []).isEmpty }
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
                        .controlSize(.small).buttonStyle(.glassProminent)
                }
                actionsMenu
            }
        }
        .task(id: entry.id) { thumb = await loadThumb(entry) }
        .sheet(isPresented: $showCustomize) { CustomizeSheet(model: model, entry: entry) }
    }

    /// The "…" actions menu — always shown: Preview, Apply-to-display (multi-monitor), Share
    /// (imported wallpapers only), Delete (installed only).
    private var actionsMenu: some View {
        Menu {
            Button { onOpen(entry) } label: { Label("Preview", systemImage: "eye") }
            if isCustomizable {
                Button { showCustomize = true } label: { Label("Customize…", systemImage: "slider.horizontal.3") }
            }
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
        .contextMenu {
            Button { onOpen(entry) } label: { Label(LocalizedStringKey("preview.menu.preview"), systemImage: "eye") }
            if isCustomizable {
                Button { showCustomize = true } label: { Label(LocalizedStringKey("preview.menu.customize"), systemImage: "slider.horizontal.3") }
            }
        }
        .help(LocalizedStringKey("preview.help"))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(appliesHere ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .topLeading) {
            if isLocked {
                Label("Premium", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6)).foregroundStyle(.yellow)
                    .clipShape(Capsule()).padding(8)
            } else if appliesHere {
                Text(LocalizedStringKey("main.active")).font(.caption2.weight(.bold))
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
            .help(isStarred ? String(localized: "preview.menu.unpin", bundle: .main)
                           : (model.canStarMore ? String(localized: "preview.menu.pin", bundle: .main)
                                              : String(format: String(localized: "main.menuBarFull", bundle: .main), AppModel.maxStars)))
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
    @State private var showCustomize = false

    private var multiMonitor: Bool { model.screens.count > 1 }
    private var isLocked: Bool { entry.isPremium && !entitlement.isPremium }
    private var isCustomizable: Bool { !(model.schemas[entry.id] ?? []).isEmpty }

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
                if isCustomizable {
                    Button { showCustomize = true } label: { Label("Customize…", systemImage: "slider.horizontal.3") }
                        .help("Adjust this wallpaper's parameters")
                }
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
                    .buttonStyle(.glassProminent)
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
                        .buttonStyle(.glassProminent)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 660)
        .sheet(isPresented: $showCustomize) { CustomizeSheet(model: model, entry: entry) }
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
                Text(LocalizedStringKey("paywall.title")).font(.title2.bold())
            }
            Text(reason).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                benefit(String(localized: "paywall.benefit.catalog", bundle: .main), "square.stack")
                benefit(String(localized: "paywall.benefit.shaders", bundle: .main), "sparkles")
                benefit(String(localized: "paywall.benefit.rotation", bundle: .main), "display.2")
                benefit(String(localized: "paywall.benefit.ai", bundle: .main), "wand.and.stars")
            }
            Text(LocalizedStringKey("paywall.pricing")).font(.caption).foregroundStyle(.secondary)

            Divider()
            Text(LocalizedStringKey("paywall.note"))
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(LocalizedStringKey("paywall.notNow")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey("paywall.checkActivation")) { Task { await entitlement.refresh(); dismiss() } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
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
    @State private var kind: AppModel.GenerateKind = .shader
    @State private var started = false

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty && AIConfig.isConfigured && !model.isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                Text(LocalizedStringKey("generate.title")).font(.headline)
            }
            Text(LocalizedStringKey("generate.body"))
                .font(.caption).foregroundStyle(.secondary)

            Picker(LocalizedStringKey("generate.type"), selection: $kind) {
                ForEach(AppModel.GenerateKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            // A TextEditor (not a line-capped TextField): scrolls natively for long prompts and
            // pastes cleanly. Placeholder is an overlay since TextEditor has none of its own.
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(LocalizedStringKey("generate.placeholder"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            if !AIConfig.isConfigured {
                Text(LocalizedStringKey("ai.sheet.notConfigured"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = model.aiError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                    Text(LocalizedStringKey("generate.generating")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(LocalizedStringKey("generate.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey("generate.generate")) { started = true; model.generate(prompt, kind: kind) }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
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
        model.screens.first(where: { $0.id == effectiveTarget })?.name ?? String(localized: "main.allDisplays", bundle: .main)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.screens.count > 1 {
                    MonitorStrip(model: model, target: $target)
                    Text(LocalizedStringKey("tab.installed.targetLine"))
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
        .navigationTitle(Text(LocalizedStringKey("tab.installed.title")))
        .navigationSubtitle(Text(String(format: String(localized: "tab.installed.subtitle", bundle: .main), model.available.count, AppModel.maxStars)))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if entitlement.isPremium { showGenerate = true }
                    else { model.showPaywall(String(localized: "paywall.feature.ai", bundle: .main)) }
                } label: { Label(LocalizedStringKey("tab.installed.generate"), systemImage: "wand.and.stars") }
                .help(LocalizedStringKey("tab.installed.generate.help"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.onImport?() } label: { Label(LocalizedStringKey("tab.installed.import"), systemImage: "plus") }
                    .help(LocalizedStringKey("tab.installed.import.help"))
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
            model: model,
            onInstall: { item in await model.onInstall?(item) ?? String(localized: "workshop.error.installUnavailable", bundle: .main) },
            screens: model.screens,
            onInstallToScreen: { item, key in await model.onInstallToScreen?(item, key) ?? String(localized: "workshop.error.installUnavailable", bundle: .main) },
            onLocked: { item in model.showPaywall(String(format: String(localized: "paywall.premiumRequired", bundle: .main), item.title)) },
            installedChecksums: model.installedChecksums)
        .navigationTitle(LocalizedStringKey("tab.catalog.title"))
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
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker(LocalizedStringKey("settings.ai.provider"), selection: $provider) {
                    ForEach(AIConfig.Provider.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: provider) { AIConfig.provider = provider; load() }

                TextField(LocalizedStringKey("settings.ai.baseURL"), text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURL) { AIConfig.setBaseURL(baseURL, for: provider) }
                TextField(LocalizedStringKey("settings.ai.model"), text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { AIConfig.setModel(model, for: provider) }
                SecureField(LocalizedStringKey(provider.requiresKey ? "settings.ai.apiKey" : "settings.ai.apiKeyLocal"),
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { AIConfig.setAPIKey(apiKey.isEmpty ? nil : apiKey, for: provider) }

                Text(provider.hint).font(.caption).foregroundStyle(.secondary)
                Text(LocalizedStringKey("settings.ai.byok"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(LocalizedStringKey("settings.ai"))
        }
        .onAppear(perform: load)
    }

    private func load() {
        baseURL = AIConfig.baseURL(for: provider)
        model = AIConfig.model(for: provider)
        apiKey = AIConfig.apiKey(for: provider) ?? ""
    }
}

/// The Premium status + activation panel in Settings. Licensing is **per machine**: a free trial or
/// a license code binds this Mac. Lifetime buyers self-serve extra Macs; trial/subscription users who
/// change machines contact support (see docs/BILLING.md in the backend repo). No client-side unlock
/// override — dev/staging premium is granted via the backend admin token.
struct PremiumSettings: View {
    @ObservedObject private var entitlement = Entitlement.shared
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var showCancel = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                header
                if entitlement.isPremium { premiumBody } else { freeBody }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if let info { Text(info).font(.caption).foregroundStyle(.secondary) }
                Divider().padding(.vertical, 1)
                Text(String(format: String(localized: "settings.general.device", bundle: .main), Device.id))
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    .help(LocalizedStringKey("settings.general.deviceHelp"))
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(LocalizedStringKey("settings.premium"))
        }
        .sheet(isPresented: $showCancel) {
            CancellationSheet { didCancel in
                showCancel = false
                if didCancel { entitlement.recompute(); info = String(localized: "settings.premium.infoCanceled", bundle: .main) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: entitlement.isPremium ? "checkmark.seal.fill" : "sparkles")
                .font(.title2).foregroundStyle(entitlement.isPremium ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle).font(.headline)
                Text(statusSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private var statusTitle: String {
        guard entitlement.isPremium else { return String(localized: "settings.premium.statusFree", bundle: .main) }
        if entitlement.isTrial { return String(localized: "settings.premium.statusTrial", bundle: .main) }
        if entitlement.isLifetime { return String(localized: "settings.premium.statusLifetime", bundle: .main) }
        if entitlement.isSubscription {
            let planKey = entitlement.claims?.plan == "annual" ? "settings.premium.statusAnnual" : "settings.premium.statusMonthly"
            return NSLocalizedString(planKey, bundle: .main, comment: "")
        }
        return String(localized: "settings.premium.statusActive", bundle: .main)
    }

    private var statusSubtitle: String {
        guard entitlement.isPremium else {
            return String(localized: "settings.premium.subtitleFree", bundle: .main)
        }
        if let ends = entitlement.planEndsDate {
            let d = ends.formatted(date: .abbreviated, time: .omitted)
            if entitlement.isTrial {
                let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: ends).day ?? 0)
                let unit = days == 1
                    ? String(localized: "settings.premium.subtitleTrial.day", bundle: .main)
                    : String(localized: "settings.premium.subtitleTrial.days", bundle: .main)
                return String(format: String(localized: "settings.premium.subtitleTrial", bundle: .main),
                              days, unit, d)
            }
            return String(format: String(localized: "settings.premium.subtitleLicensed", bundle: .main), d)
        }
        return String(localized: "settings.premium.subtitleActive", bundle: .main)
    }

    // MARK: Premium state

    @ViewBuilder private var premiumBody: some View {
        if entitlement.isLifetime {
            HStack {
                Button(LocalizedStringKey("settings.premium.deactivate")) { run { await entitlement.deactivate(); info = String(localized: "settings.premium.infoDeactivated", bundle: .main) } }
                    .help(LocalizedStringKey("settings.premium.deactivate.help"))
                Spacer()
            }
            Text(String(format: String(localized: "settings.premium.lifetimeMacs", bundle: .main), Licensing.DEFAULT_DEVICE_CAP))
                .font(.caption2).foregroundStyle(.secondary)
        } else if entitlement.isSubscription {
            HStack {
                Button(LocalizedStringKey("settings.premium.cancelSubscription"), role: .destructive) { showCancel = true }
                Spacer()
            }
            Text(LocalizedStringKey("settings.premium.subscriptionNote"))
                .font(.caption2).foregroundStyle(.secondary)
        } else if entitlement.isTrial {
            Text(LocalizedStringKey("settings.premium.trialNote"))
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text(LocalizedStringKey("settings.premium.activeNote")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Free state

    @ViewBuilder private var freeBody: some View {
        HStack(spacing: 8) {
            Button(LocalizedStringKey("settings.premium.startTrial")) { startTrial() }
                .buttonStyle(.glassProminent)
                .disabled(busy)
            Text(LocalizedStringKey("settings.premium.noCard")).font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        Divider().padding(.vertical, 2)
        HStack {
            TextField(LocalizedStringKey("settings.premium.licenseCode"), text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(activate)
            Button(LocalizedStringKey("settings.premium.activate"), action: activate)
                .buttonStyle(.bordered)
                .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack {
            Button(LocalizedStringKey("paywall.checkActivation")) { run { await entitlement.refresh(); if !entitlement.isPremium { info = String(localized: "settings.premium.infoNoActiveLicense", bundle: .main) } } }
                .help(LocalizedStringKey("paywall.checkActivation"))
            Spacer()
        }
        Text(LocalizedStringKey("settings.premium.licenseNote"))
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func startTrial() {
        run {
            do { try await entitlement.startTrial(); info = String(localized: "settings.premium.infoTrialActive", bundle: .main) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func activate() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        run {
            do { try await entitlement.activate(code: c); code = ""; info = String(localized: "settings.premium.infoActivated", bundle: .main) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Run an async action with the busy spinner and a cleared message area.
    private func run(_ action: @escaping () async -> Void) {
        busy = true; error = nil; info = nil
        Task { await action(); busy = false }
    }
}

/// Time-of-day wallpaper schedule editor (Premium). A list of "at HH:MM → wallpaper" rows the app
/// applies through the day. Independent of rotation.
struct ScheduleSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var entitlement = Entitlement.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(LocalizedStringKey("settings.schedule.toggle"), isOn: $prefs.scheduleEnabled)
                    .disabled(!entitlement.isPremium)

                if !entitlement.isPremium {
                    Button { model.showPaywall(String(localized: "paywall.feature.schedule", bundle: .main)) } label: {
                        Label(LocalizedStringKey("settings.premium.unlockLabel"), systemImage: "lock.fill")
                    }
                    .buttonStyle(.link).font(.caption)
                } else {
                    ForEach($prefs.scheduleEntries) { $entry in
                        HStack(spacing: 8) {
                            DatePicker("", selection: timeBinding($entry), displayedComponents: .hourAndMinute)
                                .labelsHidden().fixedSize()
                            Picker("", selection: $entry.wallpaperID) {
                                ForEach(model.available) { Text($0.title).tag($0.id) }
                            }
                            .labelsHidden()
                            Spacer(minLength: 0)
                            Button(role: .destructive) { remove(entry) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button { addEntry() } label: { Label(LocalizedStringKey("settings.schedule.addTime"), systemImage: "plus") }
                        .disabled(model.available.isEmpty)
                    Text(prefs.scheduleEntries.isEmpty
                         ? LocalizedStringKey("settings.schedule.empty")
                         : LocalizedStringKey("settings.schedule.populated"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(LocalizedStringKey("settings.schedule"))
        }
    }

    /// Bridge an entry's hour/minute to the `Date` a `DatePicker` wants (today's date, that time).
    private func timeBinding(_ entry: Binding<ScheduleEntry>) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents(); c.hour = entry.wrappedValue.hour; c.minute = entry.wrappedValue.minute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                entry.wrappedValue.hour = c.hour ?? 0
                entry.wrappedValue.minute = c.minute ?? 0
            })
    }

    private func addEntry() {
        let id = model.available.contains(where: { $0.id == model.currentID })
            ? model.currentID : (model.available.first?.id ?? "")
        guard !id.isEmpty else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        prefs.scheduleEntries.append(ScheduleEntry(hour: hour, minute: 0, wallpaperID: id))
    }

    private func remove(_ entry: ScheduleEntry) {
        prefs.scheduleEntries.removeAll { $0.id == entry.id }
    }
}

/// Energy panel: the live render state (real, from the Governor) plus a coarse per-medium cost
/// *estimate* (the app can't read GPU energy directly — honest wording matters here). Free for all;
/// it's a trust feature, not a paywalled one.
struct EnergySettings: View {
    @ObservedObject var model: AppModel

    private var pixels: Int {
        let screen = model.screens.first { $0.assignedID == model.currentID } ?? model.screens.first
        return screen.map { max(1, $0.width * $0.height) } ?? EnergyModel.referencePixels
    }
    private var currentKind: String { model.available.first { $0.id == model.currentID }?.kind ?? "metal" }
    private var estimate: EnergyEstimate {
        EnergyModel.estimate(kind: currentKind, fps: model.renderState.fps,
                             paused: model.renderState.paused, pixels: pixels)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(model.renderState.paused ? Color.gray : Color.green)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.renderState.paused
                             ? String(localized: "settings.energy.paused", bundle: .main)
                             : String(format: String(localized: "settings.energy.running", bundle: .main), model.renderState.fps))
                            .font(.subheadline.weight(.medium))
                        Text(model.renderState.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(estimate.level.rawValue)
                        .font(.caption.weight(.semibold)).foregroundStyle(color(estimate.level))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("settings.energy.estimateNote"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(["metal", "web", "video"], id: \.self) { kind in
                        let est = EnergyModel.estimate(kind: kind, fps: 60, paused: false, pixels: pixels)
                        HStack(spacing: 8) {
                            Text(label(kind)).font(.caption).frame(width: 56, alignment: .leading)
                            ProgressView(value: Double(est.score), total: 100)
                                .tint(color(est.level))
                            Text(est.level.rawValue).font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .trailing)
                        }
                    }
                }

                Text(LocalizedStringKey("settings.energy.disclaimer"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(LocalizedStringKey("settings.energy"))
        }
    }

    private func label(_ kind: String) -> String {
        let key: String
        switch kind {
        case "video": key = "settings.energy.kind.video"; break
        case "web":   key = "settings.energy.kind.web"; break
        default:      key = "settings.energy.kind.shader"; break
        }
        return NSLocalizedString(key, bundle: .main, comment: "")
    }
    private func color(_ level: EnergyEstimate.Level) -> Color {
        switch level {
        case .paused: return .gray
        case .low: return .green
        case .moderate: return .yellow
        case .high: return .orange
        }
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
                PremiumSettings()
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(LocalizedStringKey("settings.general.launchAtLogin"), isOn: $prefs.launchAtLogin)
                        Toggle(LocalizedStringKey("settings.general.solidBackdrop"), isOn: $prefs.solidBackdrop)
                        Text(LocalizedStringKey("settings.general.solidBackdrop.help"))
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Button(LocalizedStringKey("settings.general.showWelcome")) { model.onShowOnboarding?() }
                            .help(LocalizedStringKey("settings.general.showWelcome.help"))
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(LocalizedStringKey("settings.general"))
                }
                AISettings()
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(LocalizedStringKey("settings.power.battery"), selection: $prefs.batteryBehavior) {
                            ForEach(BatteryBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Text(LocalizedStringKey("settings.power.note"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(LocalizedStringKey("settings.power"))
                }
                EnergySettings(model: model)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(LocalizedStringKey("settings.rotation.toggle"), isOn: $prefs.rotationEnabled)
                            .disabled(!entitlement.isPremium)
                        Stepper(LocalizedStringKey("settings.rotation.interval"), value: $prefs.rotationMinutes, in: 1...240)
                            .disabled(!prefs.rotationEnabled || !entitlement.isPremium)
                        if !entitlement.isPremium {
                            Button { model.showPaywall(String(localized: "paywall.feature.rotation", bundle: .main)) } label: {
                                Label(LocalizedStringKey("settings.premium.unlockLabel"), systemImage: "lock.fill")
                            }
                            .buttonStyle(.link).font(.caption)
                        } else if model.screens.count > 1 {
                            Text(LocalizedStringKey("settings.rotation.note"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(LocalizedStringKey("settings.rotation"))
                }
                ScheduleSettings(model: model)
                // Per-wallpaper parameters now live on the wallpaper itself: use "Customize…" from a
                // wallpaper's actions menu (the "…"), its right-click menu, or its preview.
            }
            .padding(20)
            .frame(maxWidth: 640)                    // a comfortable reading column…
            .frame(maxWidth: .infinity)              // …centered in the now full-width window
        }
        .navigationTitle(LocalizedStringKey("settings.title"))
        .navigationSubtitle(LocalizedStringKey("settings.subtitle"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    prefs.batteryBehavior = .throttle
                    prefs.rotationEnabled = false
                    prefs.rotationMinutes = 15
                } label: { Label(LocalizedStringKey("settings.reset"), systemImage: "arrow.counterclockwise") }
                .help(LocalizedStringKey("settings.reset"))
            }
        }
    }
}

/// A wallpaper's parameter controls, backed by a `ConfigStore` recreated per wallpaper. Changes are
/// persisted (and applied live if that wallpaper is currently rendering) via `onApplyConfig`.
struct WallpaperParamRows: View {
    @StateObject private var store: ConfigStore

    init(model: AppModel, schema: [ConfigParameter], id: String) {
        let s = ConfigStore(schema: schema, values: model.configFor?(id) ?? .defaults(for: schema))
        s.onChange = { [weak model] values in model?.onApplyConfig?(id, values) }
        _store = StateObject(wrappedValue: s)
    }

    var body: some View { ConfigControls(store: store) }
}

/// A modal for tweaking one wallpaper's parameters, reached from the wallpaper's own actions menu
/// (or its preview) — so customization lives with the wallpaper instead of buried in Settings. Only
/// shown for wallpapers that actually expose parameters.
struct CustomizeSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let schema = model.schemas[entry.id] ?? []
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey("preview.menu.customize")).font(.headline)
                    Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if schema.isEmpty {
                Text(LocalizedStringKey("customize.empty"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    WallpaperParamRows(model: model, schema: schema, id: entry.id).id(entry.id)
                }
                Text(LocalizedStringKey("customize.live"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(LocalizedStringKey("action.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
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
        w.setContentSize(NSSize(width: 1075, height: 700))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
