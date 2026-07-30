import AppKit
import UniformTypeIdentifiers
import os

/// Wires the app together: one desktop window + renderer per screen, the Governor, the status-bar
/// menu (wallpaper switcher + import/export + settings), and the notifications that rebuild windows
/// on screen-layout changes and report occlusion to the Governor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "AppDelegate")
    private let governor = Governor()
    private let library = Library()
    private let settingsController = SettingsWindowController()
    private let prefsController = PreferencesWindowController()
    private var rotationTimer: Timer?

    private var statusItem: NSStatusItem?
    private var statusStateItem: NSMenuItem?

    private struct Screenlet {
        let screen: NSScreen
        let id: String
        let window: DesktopWindow
        let renderer: any WallpaperRenderer
        let schema: [ConfigParameter]
    }
    private var screenlets: [Screenlet] = []

    /// Installed packages, refreshed each rebuild.
    private var installed: [WallpaperPackage] = []
    /// Live config values per wallpaper id.
    private var configByID: [String: [String: ConfigValue]] = [:]
    /// The wallpaper the settings panel targets (the one on the main screen).
    private var currentID = WallpaperCatalog.defaultID

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        governor.onChange = { [weak self] directive in
            guard let self else { return }
            for s in self.screenlets { s.renderer.apply(directive) }
            self.updateStatusTitle(directive)
        }
        governor.start()
        loadConfig()
        rebuildScreenlets()

        // React to preference changes (battery behavior, rotation).
        Preferences.shared.onChange = { [weak self] in
            self?.governor.preferencesChanged()
            self?.restartRotation()
        }
        restartRotation()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildScreenlets() } }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reportOcclusion() } }
    }

    // MARK: - Windows

    private func rebuildScreenlets() {
        for s in screenlets { s.renderer.stop(); s.window.orderOut(nil) }
        screenlets.removeAll()
        installed = library.installedPackages()

        // Test hook: LW_DEFAULT overrides the default wallpaper for a fresh launch.
        let defaultID = ProcessInfo.processInfo.environment["LW_DEFAULT"] ?? WallpaperCatalog.defaultID
        for screen in NSScreen.screens {
            let id = library.assignedID(for: screen, default: defaultID)
            let (renderer, schema, resolvedID) = makeRenderer(forID: id)

            let window = DesktopWindow(screen: screen)
            window.orderFront(nil)
            if let layer = window.renderLayer { renderer.start(in: layer) }

            let values = configByID[resolvedID] ?? .defaults(for: schema)
            configByID[resolvedID] = values
            renderer.apply(config: values)
            renderer.apply(governor.current)

            screenlets.append(Screenlet(screen: screen, id: resolvedID, window: window,
                                        renderer: renderer, schema: schema))
        }

        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        currentID = screenlets.first(where: { $0.screen == mainScreen })?.id ?? WallpaperCatalog.defaultID
        log.notice("Rebuilt \(self.screenlets.count) screen(s); \(self.installed.count) installed package(s).")
        reportOcclusion()
        rebuildMenu()
    }

    /// Resolve a wallpaper id to a renderer. Falls back to the default shader if the id is unknown or
    /// unsupported (e.g. a `web` package before M3).
    private func makeRenderer(forID id: String) -> (any WallpaperRenderer, [ConfigParameter], String) {
        if let item = WallpaperCatalog.all.first(where: { $0.id == id }) {
            let r = item.make(); return (r, r.configSchema, id)
        }
        if let pkg = installed.first(where: { $0.manifest.id == id }) {
            do { let r = try pkg.makeRenderer(); return (r, r.configSchema, id) }
            catch { log.error("Package '\(id, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)") }
        }
        let fallback = WallpaperCatalog.item(id: WallpaperCatalog.defaultID)
        let r = fallback.make(); return (r, r.configSchema, fallback.id)
    }

    private func reportOcclusion() {
        governor.setAnyWindowVisible(screenlets.contains { $0.window.occlusionState.contains(.visible) })
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🖼️"
        status.button?.toolTip = "LiveWallpaper"
        self.statusItem = status
        rebuildMenu()
    }

    /// (id, title) for every selectable wallpaper: built-ins first, then installed packages.
    private func wallpaperEntries() -> [(id: String, title: String)] {
        WallpaperCatalog.all.map { ($0.id, $0.title) }
            + installed.map { ($0.manifest.id, "◆ " + $0.manifest.title) }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: "State: \(governor.current.description)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        self.statusStateItem = stateItem
        menu.addItem(.separator())

        let screens = NSScreen.screens
        let entries = wallpaperEntries()

        if screens.count <= 1 {
            // Single display: a flat list.
            let header = NSMenuItem(title: "Wallpaper", action: nil, keyEquivalent: ""); header.isEnabled = false
            menu.addItem(header)
            let assigned = screens.first.map { library.assignedID(for: $0, default: WallpaperCatalog.defaultID) }
            for e in entries {
                let mi = NSMenuItem(title: e.title, action: #selector(selectWallpaperAll(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = e.id
                mi.state = (e.id == assigned) ? .on : .off
                menu.addItem(mi)
            }
        } else {
            // Multiple displays: one submenu per screen.
            for screen in screens {
                let assigned = library.assignedID(for: screen, default: WallpaperCatalog.defaultID)
                let sub = NSMenu()
                for e in entries {
                    let mi = NSMenuItem(title: e.title, action: #selector(selectWallpaperForScreen(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = ["screen": Library.key(for: screen), "id": e.id]
                    mi.state = (e.id == assigned) ? .on : .off
                    sub.addItem(mi)
                }
                let item = NSMenuItem(title: "Display: \(screen.localizedName)", action: nil, keyEquivalent: "")
                menu.addItem(item); menu.setSubmenu(sub, for: item)
            }
        }

        menu.addItem(.separator())
        addItem(to: menu, "Import Wallpaper…", #selector(importWallpaper), key: "o")
        addItem(to: menu, "Export Sample Wallpaper…", #selector(exportSample), key: "e")
        let settings = addItem(to: menu, "Wallpaper Settings…", #selector(openSettings), key: "")
        settings.isEnabled = !(screenlets.first(where: { $0.id == currentID })?.schema.isEmpty ?? true)
        addItem(to: menu, "Preferences…", #selector(openPreferences), key: ",")

        menu.addItem(.separator())
        addItem(to: menu, "Quit LiveWallpaper", #selector(quit), key: "q")

        statusItem?.menu = menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self; menu.addItem(mi); return mi
    }

    private func updateStatusTitle(_ directive: RenderDirective) {
        statusStateItem?.title = "State: \(directive.description)"
        statusItem?.button?.title = directive.paused ? "🖼️⏸" : "🖼️"
    }

    // MARK: - Actions

    @objc private func selectWallpaperAll(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        library.assignToAll(id, screens: NSScreen.screens)
        rebuildScreenlets()
    }

    @objc private func selectWallpaperForScreen(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: String],
              let id = dict["id"], let key = dict["screen"],
              let screen = NSScreen.screens.first(where: { Library.key(for: $0) == key }) else { return }
        library.assign(id, to: screen)
        rebuildScreenlets()
    }

    @objc private func importWallpaper() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "livewallpaper") ?? .zip, .zip]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pkg = try library.install(fromZipAt: url)
            library.assignToAll(pkg.manifest.id, screens: NSScreen.screens)
            rebuildScreenlets()
        } catch {
            presentError("Could not import wallpaper", error)
        }
    }

    @objc private func exportSample() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "livewallpaper") ?? .zip]
        panel.nameFieldStringValue = "Plasma.livewallpaper"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportShader(
                id: "sample.plasma", title: "Plasma (sample)",
                source: BuiltInShaders.plasma,
                config: Self.manifestConfig(from: WallpaperCatalog.shaderConfig),
                to: url)
        } catch {
            presentError("Could not export wallpaper", error)
        }
    }

    @objc private func openSettings() {
        guard let schema = screenlets.first(where: { $0.id == currentID })?.schema, !schema.isEmpty else { return }
        let values = configByID[currentID] ?? .defaults(for: schema)
        let store = ConfigStore(schema: schema, values: values)
        store.onChange = { [weak self] values in
            guard let self else { return }
            self.configByID[self.currentID] = values
            for s in self.screenlets where s.id == self.currentID { s.renderer.apply(config: values) }
            self.saveConfig()
        }
        let title = wallpaperEntries().first(where: { $0.id == currentID })?.title ?? "Wallpaper"
        settingsController.show(store: store, title: title)
    }

    @objc private func openPreferences() { prefsController.show() }

    @objc private func quit() {
        for s in screenlets { s.renderer.stop() }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Config persistence

    private func loadConfig() {
        guard let data = UserDefaults.standard.data(forKey: "configByID"),
              let decoded = try? JSONDecoder().decode([String: [String: ConfigValue]].self, from: data)
        else { return }
        configByID = decoded
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(configByID) {
            UserDefaults.standard.set(data, forKey: "configByID")
        }
    }

    // MARK: - Rotation

    private func restartRotation() {
        rotationTimer?.invalidate(); rotationTimer = nil
        guard Preferences.shared.rotationEnabled else { return }
        let interval = TimeInterval(max(1, Preferences.shared.rotationMinutes) * 60)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotateWallpaper() }
        }
    }

    private func rotateWallpaper() {
        let entries = wallpaperEntries()
        guard entries.count > 1, let main = NSScreen.main ?? NSScreen.screens.first else { return }
        let current = library.assignedID(for: main, default: WallpaperCatalog.defaultID)
        let idx = entries.firstIndex { $0.id == current } ?? -1
        let next = entries[(idx + 1) % entries.count]
        library.assignToAll(next.id, screens: NSScreen.screens)
        rebuildScreenlets()
    }

    // MARK: - Helpers

    private func presentError(_ message: String, _ error: Error) {
        log.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Convert the shared config schema to manifest `config` entries (for export).
    private static func manifestConfig(from schema: [ConfigParameter]) -> [Manifest.ConfigEntry] {
        schema.map { p in
            switch p.kind {
            case let .float(min, max, def):
                return Manifest.ConfigEntry(key: p.key, type: "float", label: p.label,
                                            min: min, max: max, options: nil, defaultValue: .double(def))
            case let .bool(def):
                return Manifest.ConfigEntry(key: p.key, type: "bool", label: p.label,
                                            min: nil, max: nil, options: nil, defaultValue: .bool(def))
            case let .color(def):
                return Manifest.ConfigEntry(key: p.key, type: "color", label: p.label,
                                            min: nil, max: nil, options: nil, defaultValue: .string(def))
            }
        }
    }
}
