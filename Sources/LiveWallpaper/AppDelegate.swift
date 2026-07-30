import AppKit
import os

/// Wires the app together: one desktop window + renderer per screen, the Governor, the status-bar
/// menu (wallpaper switcher + settings), and the notifications that rebuild windows on screen-layout
/// changes and report occlusion to the Governor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "AppDelegate")
    private let governor = Governor()
    private let settingsController = SettingsWindowController()

    private var statusItem: NSStatusItem?
    private var statusStateItem: NSMenuItem?

    /// One entry per screen.
    private struct Screenlet {
        let window: DesktopWindow
        let renderer: any WallpaperRenderer
    }
    private var screenlets: [Screenlet] = []

    // Current selection + live config values for it.
    private var currentID = UserDefaults.standard.string(forKey: "wallpaperID") ?? WallpaperCatalog.defaultID
    private var currentSchema: [ConfigParameter] = []
    private var configValues: [String: ConfigValue] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        governor.onChange = { [weak self] directive in
            guard let self else { return }
            for s in self.screenlets { s.renderer.apply(directive) }
            self.updateStatusTitle(directive)
        }
        governor.start()

        rebuildScreenlets()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreenlets() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportOcclusion() }
        }
    }

    // MARK: - Windows

    private func rebuildScreenlets() {
        for s in screenlets {
            s.renderer.stop()
            s.window.orderOut(nil)
        }
        screenlets.removeAll()

        let item = WallpaperCatalog.item(id: currentID)

        for screen in NSScreen.screens {
            let window = DesktopWindow(screen: screen)
            let renderer = item.make()
            window.orderFront(nil)
            if let layer = window.renderLayer {
                renderer.start(in: layer)
            }
            // On the first renderer, sync the schema and (re)seed config values if needed.
            if screenlets.isEmpty {
                currentSchema = renderer.configSchema
                if Set(configValues.keys) != Set(currentSchema.map(\.key)) {
                    configValues = .defaults(for: currentSchema)
                }
            }
            renderer.apply(config: configValues)
            renderer.apply(governor.current)
            screenlets.append(Screenlet(window: window, renderer: renderer))
        }
        log.notice("Built \(self.screenlets.count) desktop window(s) for '\(item.title, privacy: .public)'.")
        reportOcclusion()
        rebuildMenu()
    }

    private func reportOcclusion() {
        let anyVisible = screenlets.contains { $0.window.occlusionState.contains(.visible) }
        governor.setAnyWindowVisible(anyVisible)
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🖼️"
        status.button?.toolTip = "LiveWallpaper"
        self.statusItem = status
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: "State: \(governor.current.description)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        self.statusStateItem = stateItem
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Wallpaper", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in WallpaperCatalog.all {
            let mi = NSMenuItem(title: item.title, action: #selector(selectWallpaper(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.id
            mi.state = (item.id == currentID) ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = !currentSchema.isEmpty
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LiveWallpaper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func updateStatusTitle(_ directive: RenderDirective) {
        statusStateItem?.title = "State: \(directive.description)"
        statusItem?.button?.title = directive.paused ? "🖼️⏸" : "🖼️"
    }

    // MARK: - Actions

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != currentID else { return }
        currentID = id
        UserDefaults.standard.set(id, forKey: "wallpaperID")
        configValues = [:]   // reseed from the new wallpaper's schema in rebuild
        rebuildScreenlets()
    }

    @objc private func openSettings() {
        guard !currentSchema.isEmpty else { return }
        let store = ConfigStore(schema: currentSchema, values: configValues)
        store.onChange = { [weak self] values in
            guard let self else { return }
            self.configValues = values
            for s in self.screenlets { s.renderer.apply(config: values) }
        }
        settingsController.show(store: store, title: WallpaperCatalog.item(id: currentID).title)
    }

    @objc private func quit() {
        for s in screenlets { s.renderer.stop() }
        NSApplication.shared.terminate(nil)
    }
}
