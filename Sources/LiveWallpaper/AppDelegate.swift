import AppKit
import UniformTypeIdentifiers
import os

/// Wires the app together: per-screen rendering, the Governor, the shared `AppModel`, the main
/// window (Installed/Explore/Settings), and a compact menu bar (app name → pinned wallpapers →
/// Open LiveWallpaper → Quit → version).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "AppDelegate")
    private let governor = Governor()
    private let library = Library()
    private let model = AppModel()
    private let mainWindow = MainWindowController()

    private var statusItem: NSStatusItem?
    private var rotationTimer: Timer?

    private struct Screenlet {
        let screen: NSScreen
        let id: String
        let window: DesktopWindow
        let renderer: any WallpaperRenderer
    }
    private var screenlets: [Screenlet] = []
    private var installed: [WallpaperPackage] = []
    private var configByID: [String: [String: ConfigValue]] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        wireModel()

        governor.onChange = { [weak self] directive in
            guard let self else { return }
            for s in self.screenlets { s.renderer.apply(directive) }
            self.updateStatusIcon(directive)
        }
        governor.start()
        loadConfig()
        rebuildScreenlets()

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

        if ProcessInfo.processInfo.environment["LW_OPEN_WINDOW"] != nil { openMainWindow() }
    }

    // MARK: - Model wiring

    private func wireModel() {
        model.onSetActive = { [weak self] id in self?.activate(id) }
        model.onImport = { [weak self] in self?.importWallpaper() }
        model.onStarsChanged = { [weak self] in self?.rebuildMenu() }
        model.onRemove = { [weak self] id in
            guard let self else { return }
            self.library.remove(id: id)
            if self.model.currentID == id { self.library.assignToAll(WallpaperCatalog.defaultID, screens: NSScreen.screens) }
            self.rebuildScreenlets()
        }
        model.onInstall = { [weak self] item in await self?.install(item) ?? "Install unavailable." }
        model.configFor = { [weak self] id in
            self?.configByID[id] ?? .defaults(for: self?.model.schemas[id] ?? [])
        }
        model.onApplyConfig = { [weak self] id, values in
            guard let self else { return }
            self.configByID[id] = values
            self.saveConfig()
            for s in self.screenlets where s.id == id { s.renderer.apply(config: values) }
        }
    }

    // MARK: - Rendering

    private func activate(_ id: String) {
        library.assignToAll(id, screens: NSScreen.screens)
        rebuildScreenlets()
    }

    private func rebuildScreenlets() {
        for s in screenlets { s.renderer.stop(); s.window.orderOut(nil) }
        screenlets.removeAll()
        installed = library.installedPackages()

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
            screenlets.append(Screenlet(screen: screen, id: resolvedID, window: window, renderer: renderer))
        }
        syncModel()
        reportOcclusion()
        rebuildMenu()
    }

    private func makeRenderer(forID id: String) -> (any WallpaperRenderer, [ConfigParameter], String) {
        if let item = WallpaperCatalog.all.first(where: { $0.id == id }) {
            let r = item.make(); return (r, r.configSchema, id)
        }
        if let pkg = installed.first(where: { $0.manifest.id == id }) {
            do { let r = try pkg.makeRenderer(); return (r, r.configSchema, id) }
            catch { log.error("Package '\(id, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)") }
        }
        let fb = WallpaperCatalog.item(id: WallpaperCatalog.defaultID)
        let r = fb.make(); return (r, r.configSchema, fb.id)
    }

    /// Rebuild the model's available list + schemas + current id from the library.
    private func syncModel() {
        var entries = WallpaperCatalog.all.map {
            AppModel.Entry(id: $0.id, title: $0.title, kind: $0.kind, isBuiltIn: true)
        }
        entries += installed.map {
            AppModel.Entry(id: $0.manifest.id, title: $0.manifest.title, kind: $0.manifest.type.rawValue, isBuiltIn: false)
        }
        model.available = entries

        var schemas: [String: [ConfigParameter]] = [:]
        for it in WallpaperCatalog.all {
            schemas[it.id] = it.kind == "metal" ? WallpaperCatalog.shaderConfig : []
        }
        for pkg in installed { schemas[pkg.manifest.id] = pkg.manifest.configSchema() }
        model.schemas = schemas

        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        model.currentID = screenlets.first(where: { $0.screen == mainScreen })?.id ?? WallpaperCatalog.defaultID
        model.pruneStars()
    }

    private func reportOcclusion() {
        governor.setAnyWindowVisible(screenlets.contains { $0.window.occlusionState.contains(.visible) })
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🖼️"
        status.button?.toolTip = "LiveWallpaper"
        statusItem = status
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "LiveWallpaper", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let entries = model.menuEntries()
        if entries.isEmpty {
            let none = NSMenuItem(title: "No wallpapers", action: nil, keyEquivalent: ""); none.isEnabled = false
            menu.addItem(none)
        } else {
            for e in entries {
                let mi = NSMenuItem(title: e.title, action: #selector(menuSelect(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = e.id
                mi.state = (e.id == model.currentID) ? .on : .off
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        add(menu, "Open LiveWallpaper", #selector(openMainWindow), key: "o")
        add(menu, "Quit LiveWallpaper", #selector(quit), key: "q")
        menu.addItem(.separator())
        let version = NSMenuItem(title: "v\(model.appVersion)", action: nil, keyEquivalent: ""); version.isEnabled = false
        menu.addItem(version)

        statusItem?.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
    }

    private func updateStatusIcon(_ directive: RenderDirective) {
        statusItem?.button?.title = directive.paused ? "🖼️⏸" : "🖼️"
        rebuildMenu()   // refresh the active checkmark
    }

    // MARK: - Actions

    @objc private func menuSelect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setActive(id)
    }

    @objc private func openMainWindow() { mainWindow.show(model: model) }

    private func install(_ item: WorkshopItem) async -> String? {
        do {
            let url = try await model.workshop.downloadBundle(item)
            let pkg = try library.install(fromZipAt: url)
            await model.workshop.incrementDownload(item.id)
            library.assignToAll(pkg.manifest.id, screens: NSScreen.screens)
            rebuildScreenlets()
            return nil
        } catch {
            return error.localizedDescription
        }
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
            MainActor.assumeIsolated { self?.rotate() }
        }
    }

    private func rotate() {
        let ids = model.available.map(\.id)
        guard ids.count > 1 else { return }
        let idx = ids.firstIndex(of: model.currentID) ?? -1
        activate(ids[(idx + 1) % ids.count])
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
}
