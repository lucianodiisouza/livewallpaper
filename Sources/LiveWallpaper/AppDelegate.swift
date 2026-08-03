import AppKit
import Combine
import UniformTypeIdentifiers
import os

/// Wires the app together: per-screen rendering, the Governor, the shared `AppModel`, the main
/// window (Installed/Explore/Settings), and a compact menu bar (app name → pinned wallpapers →
/// Open Primo Engine → Quit → version).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "AppDelegate")
    private let governor = Governor()
    private let library = Library()
    private let model = AppModel()
    private let mainWindow = MainWindowController()
    private let onboarding = OnboardingWindowController()

    private var statusItem: NSStatusItem?
    private var rotationTimer: Timer?
    private var scheduleTimer: Timer?
    /// The wallpaper the schedule last applied — so we don't re-apply every tick, and the user can
    /// manually override until the next scheduled time.
    private var lastScheduleWallpaperID: String?
    private var cancellables = Set<AnyCancellable>()
    /// Set once a launch-time (or manual) check finds a newer release; surfaces in the menu.
    private var availableUpdate: UpdateChecker.Outcome?

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
            self.model.renderState = AppModel.RenderState(
                paused: directive.paused, fps: directive.fps, reason: self.governor.statusReason)
        }
        governor.start()
        model.renderState = AppModel.RenderState(
            paused: governor.current.paused, fps: governor.current.fps, reason: governor.statusReason)
        loadConfig()
        rebuildScreenlets()
        applyBackdropIfEnabled()

        Preferences.shared.onChange = { [weak self] in
            self?.governor.preferencesChanged()
            self?.restartRotation()
            self?.restartSchedule()
            self?.applyBackdropIfEnabled()
        }
        restartRotation()
        restartSchedule()

        // Rotation + schedule are Premium-gated; re-evaluate whenever the entitlement flips.
        Entitlement.shared.$isPremium
            .sink { [weak self] _ in self?.restartRotation(); self?.restartSchedule() }
            .store(in: &cancellables)
        // Renew the device-bound license if it's missing or near expiry (no-op if unconfigured/
        // offline, or if the cached license is still comfortably valid).
        Task { await Entitlement.shared.refreshIfNeeded() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildScreenlets(); self?.applyBackdropIfEnabled() } }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reportOcclusion() } }

        // Active-Space / app-activation changes are when a full-screen app takes over and occlusion is
        // slowest to fire — re-poll occlusion AND the explicit full-screen-cover signal right then.
        let wsc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            wsc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportOcclusion(); self?.governor.updateFullscreenCoverage() }
            }
        }

        if ProcessInfo.processInfo.environment["LW_OPEN_WINDOW"] != nil { openMainWindow() }

        // First run (or forced via LW_ONBOARDING=1): show the walkthrough. `available` is already
        // populated by rebuildScreenlets() above, so the "pick a wallpaper" step has content.
        if ProcessInfo.processInfo.environment["LW_ONBOARDING"] == "1" || !Preferences.shared.hasCompletedOnboarding {
            showOnboarding()
        }

        maybeAutoCheckForUpdates()
    }

    // MARK: - Model wiring

    private func wireModel() {
        model.onSetActive = { [weak self] id in self?.activate(id) }
        model.onAssign = { [weak self] id, screenKey in self?.assign(id, toScreenKey: screenKey) }
        model.onImport = { [weak self] in self?.importWallpaper() }
        model.onExport = { [weak self] id in self?.exportWallpaper(id) }
        model.makePreviewRenderer = { [weak self] id in self?.makeRenderer(forID: id).0 }
        model.onGenerate = { [weak self] prompt, kind in self?.generate(prompt, kind: kind) }
        model.onStarsChanged = { [weak self] in self?.rebuildMenu() }
        model.onRemove = { [weak self] id in
            guard let self else { return }
            self.library.remove(id: id)
            if self.model.currentID == id { self.library.assignToAll(WallpaperCatalog.defaultID, screens: NSScreen.screens) }
            self.rebuildScreenlets()
        }
        model.onInstall = { [weak self] item in await self?.install(item, toScreenKey: nil) ?? "Install unavailable." }
        model.onInstallToScreen = { [weak self] item, key in await self?.install(item, toScreenKey: key) ?? "Install unavailable." }
        model.configFor = { [weak self] id in
            self?.configByID[id] ?? .defaults(for: self?.model.schemas[id] ?? [])
        }
        model.onApplyConfig = { [weak self] id, values in
            guard let self else { return }
            self.configByID[id] = values
            self.saveConfig()
            for s in self.screenlets where s.id == id { s.renderer.apply(config: values) }
        }
        model.onShowOnboarding = { [weak self] in self?.showOnboarding() }
    }

    /// Present the first-run walkthrough. "Get Started" opens the main window; any dismissal marks
    /// onboarding complete (handled inside the controller via `Preferences`).
    private func showOnboarding() {
        onboarding.show(model: model, openMain: { [weak self] in self?.openMainWindow() })
    }

    // MARK: - Rendering

    private func activate(_ id: String) {
        library.assignToAll(id, screens: NSScreen.screens)
        rebuildScreenlets()
    }

    /// Assign one wallpaper to a single display, leaving the others as they are. Swaps just that
    /// screen's renderer in place (reusing its window, with a crossfade) instead of rebuilding every
    /// screenlet — so the other monitors don't flash and the change on this one is disguised.
    private func assign(_ id: String, toScreenKey key: String) {
        guard let screen = NSScreen.screens.first(where: { Library.key(for: $0) == key }) else { return }
        library.assign(id, to: screen)
        updateScreen(key: key, toID: id)
    }

    /// Replace one screenlet's renderer in its existing window with a fade. Falls back to a full
    /// rebuild if the screen isn't currently mounted (e.g. it was just plugged in).
    private func updateScreen(key: String, toID id: String) {
        guard let idx = screenlets.firstIndex(where: { Library.key(for: $0.screen) == key }) else {
            rebuildScreenlets(); return
        }
        installed = library.installedPackages()
        let old = screenlets[idx]
        let (renderer, schema, resolvedID) = makeRenderer(forID: id)

        if let layer = old.window.renderLayer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.35
            layer.add(fade, forKey: "wallpaperSwap")
            old.renderer.stop()               // removes the old sublayer (animated by the transition)
            renderer.start(in: layer)         // adds the new sublayer
        } else {
            old.renderer.stop()
        }

        let values = configByID[resolvedID] ?? .defaults(for: schema)
        configByID[resolvedID] = values
        renderer.apply(config: values)
        renderer.apply(governor.current)
        screenlets[idx] = Screenlet(screen: old.screen, id: resolvedID, window: old.window, renderer: renderer)

        syncModel()
        reportOcclusion()
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
        let bundledLoop = Bundle.main.url(forResource: "loop", withExtension: "mp4")
            ?? Bundle.main.url(forResource: "loop", withExtension: "mov")
        var entries = WallpaperCatalog.all.map {
            AppModel.Entry(id: $0.id, title: $0.title, kind: $0.kind, isBuiltIn: true,
                           previewSource: WallpaperCatalog.shaderSource(forID: $0.id),
                           previewVideoURL: $0.kind == "video" ? bundledLoop : nil,
                           isPremium: $0.isPremium)
        }
        entries += installed.map { pkg -> AppModel.Entry in
            var source: String?
            var videoURL: URL?
            if pkg.manifest.type == .metal {
                source = try? String(contentsOf: pkg.directory.appendingPathComponent(pkg.manifest.entry), encoding: .utf8)
            } else if pkg.manifest.type == .video {
                videoURL = pkg.directory.appendingPathComponent(pkg.manifest.entry)
            }
            return AppModel.Entry(id: pkg.manifest.id, title: pkg.manifest.title,
                                  kind: pkg.manifest.type.rawValue, isBuiltIn: false,
                                  previewSource: source, previewVideoURL: videoURL,
                                  isShareable: library.isImported(pkg.manifest.id))
        }
        model.available = entries
        model.installedChecksums = Set(installed.compactMap { $0.manifest.checksum })

        var schemas: [String: [ConfigParameter]] = [:]
        for it in WallpaperCatalog.all {
            schemas[it.id] = it.kind == "metal" ? WallpaperCatalog.shaderConfig : []
        }
        for pkg in installed { schemas[pkg.manifest.id] = pkg.manifest.configSchema() }
        model.schemas = schemas

        model.screens = NSScreen.screens.map { screen in
            let key = Library.key(for: screen)
            let assigned = screenlets.first(where: { Library.key(for: $0.screen) == key })?.id
                ?? library.assignedID(for: screen, default: WallpaperCatalog.defaultID)
            let scale = screen.backingScaleFactor
            return AppModel.ScreenInfo(
                id: key, name: screen.localizedName,
                width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale),
                frame: screen.frame, assignedID: assigned)
        }

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
        // Menu-bar glyph: the prism from the app icon. Use a monochrome SF Symbol template so it
        // auto-tints for the light/dark menu bar; fall back gracefully if a symbol is unavailable.
        if let img = ["prism.fill", "prism", "triangle.fill"].lazy
            .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: "Primo Engine") })
            .first {
            img.isTemplate = true
            status.button?.image = img
        } else {
            status.button?.title = "🔺"
        }
        status.button?.toolTip = "Primo Engine"
        statusItem = status
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Primo Engine", action: nil, keyEquivalent: "")
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
        if let update = availableUpdate {
            let banner = NSMenuItem(title: "🔔 Update available: v\(update.latestVersion)",
                                    action: #selector(openReleasePage), keyEquivalent: "")
            banner.target = self
            menu.addItem(banner)
        }
        add(menu, "Open Primo Engine", #selector(openMainWindow), key: "o")
        add(menu, "Check for Updates…", #selector(checkForUpdatesManually), key: "")
        add(menu, "Quit Primo Engine", #selector(quit), key: "q")
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
        // Keep the prism glyph the *only* thing in the menu bar — never stack an emoji
        // title next to the template image. Pause state just dims the same glyph.
        if let button = statusItem?.button {
            button.title = ""
            button.appearsDisabled = directive.paused
        }
        rebuildMenu()   // refresh the active checkmark
    }

    // MARK: - Actions

    @objc private func menuSelect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setActive(id)
    }

    @objc private func openMainWindow() { mainWindow.show(model: model) }

    // MARK: - Update check

    /// Silent, throttled launch-time check. On a newer release it just lights up the menu — no alert,
    /// no nagging. Skips entirely when the user has opted out.
    private func maybeAutoCheckForUpdates() {
        guard Preferences.shared.checkForUpdatesAutomatically, UpdateChecker.shouldAutoCheck() else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await UpdateChecker.fetchLatest(currentVersion: self.model.appVersion)
                UpdateChecker.recordCheck()
                if outcome.isNewer {
                    self.availableUpdate = outcome
                    self.rebuildMenu()
                    self.log.notice("Update available: \(outcome.latestVersion, privacy: .public)")
                }
            } catch {
                // A failed check is non-fatal and silent — offline testers shouldn't see errors.
                self.log.info("Update check skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Explicit "Check for Updates…" — always hits the network and always reports the result.
    @objc private func checkForUpdatesManually() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await UpdateChecker.fetchLatest(currentVersion: self.model.appVersion)
                UpdateChecker.recordCheck()
                if outcome.isNewer {
                    self.availableUpdate = outcome
                    self.rebuildMenu()
                    self.presentUpdateAvailable(outcome)
                } else {
                    self.presentUpToDate()
                }
            } catch {
                self.presentError("Couldn't check for updates", error)
            }
        }
    }

    @objc private func openReleasePage() {
        if let url = availableUpdate?.releaseURL { NSWorkspace.shared.open(url) }
    }

    private func presentUpdateAvailable(_ outcome: UpdateChecker.Outcome) {
        let alert = NSAlert()
        alert.messageText = "A new version is available"
        alert.informativeText = "Primo Engine \(outcome.latestVersion) is out — you have \(model.appVersion)."
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(outcome.releaseURL) }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Primo Engine \(model.appVersion) is the latest version."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Download + install a workshop item, then apply it to one display (`key`) or all (`nil`).
    private func install(_ item: WorkshopItem, toScreenKey key: String?) async -> String? {
        do {
            let url = try await model.workshop.downloadBundle(item)
            let pkg = try library.install(fromZipAt: url)
            await model.workshop.incrementDownload(item.id)
            library.markFromCatalog(pkg.manifest.id)   // catalog content is not P2P-shareable
            if let key, let screen = NSScreen.screens.first(where: { Library.key(for: $0) == key }) {
                library.assign(pkg.manifest.id, to: screen)
            } else {
                library.assignToAll(pkg.manifest.id, screens: NSScreen.screens)
            }
            rebuildScreenlets()   // structural: a new package exists — full rebuild is correct here
            return nil
        } catch let e as WorkshopClient.WorkshopError {
            // The UI's Premium unlock and the backend's device flag are separate gates: a local dev
            // override (or a cached-but-revoked license) can flip the UI to Premium while the backend
            // still refuses the download (402). For those failures, re-open the paywall so the miss is
            // unmistakable and the user can actually activate this device — instead of leaving a tiny
            // banner that reads as "nothing happened."
            if e.requiresPaywall { model.showPaywall(e.errorDescription ?? "This wallpaper is Premium.") }
            return e.errorDescription
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
            library.markImported(pkg.manifest.id)   // user-imported ⇒ P2P-shareable
            library.assignToAll(pkg.manifest.id, screens: NSScreen.screens)
            rebuildScreenlets()
        } catch {
            presentError("Could not import wallpaper", error)
        }
    }

    // MARK: - AI generation

    private static let aiConfig: [Manifest.ConfigEntry] = [
        .init(key: "speed", type: "float", label: "Speed", min: 0.1, max: 3, options: nil, defaultValue: .double(1)),
        .init(key: "tint", type: "color", label: "Tint", min: nil, max: nil, options: nil, defaultValue: .string("#FFFFFF")),
    ]

    /// Generate a wallpaper (shader or web) from a prompt: ask the model → validate (one repair
    /// retry) → package + install → apply. Premium-gated (the moat feature).
    private func generate(_ prompt: String, kind: AppModel.GenerateKind) {
        guard Entitlement.shared.isPremium else { model.showPaywall("AI generation is a Premium feature."); return }
        model.isGenerating = true
        model.aiError = nil
        Task {
            do {
                let id = "ai." + UUID().uuidString.prefix(8).lowercased()
                let title = "AI · " + prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(28)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).livewallpaper")
                switch kind {
                case .shader:
                    let src = try await self.buildValidatedShader(prompt: prompt)
                    try self.library.exportShader(id: id, title: String(title), source: src,
                                                  config: Self.aiConfig, to: dest, authorHandle: "ai")
                case .web:
                    let html = try await self.buildValidatedWeb(prompt: prompt)
                    try self.library.exportWeb(id: id, title: String(title), html: html, to: dest, authorHandle: "ai")
                }
                let pkg = try self.library.install(fromZipAt: dest)
                self.library.markImported(pkg.manifest.id)   // the user's own creation ⇒ shareable
                try? FileManager.default.removeItem(at: dest)
                self.model.isGenerating = false
                self.activate(pkg.manifest.id)               // rebuild + apply to the desktop
            } catch {
                self.model.isGenerating = false
                self.model.aiError = error.localizedDescription
                self.log.error("AI generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Generate → prepend the fixed prelude → validate + compile; one repair retry on failure.
    private func buildValidatedShader(prompt: String) async throws -> String {
        var full = BuiltInShaders.prelude + "\n\n" + (try await ShaderGenerator.generate(prompt: prompt))
        if !Self.isValidShader(full) {
            let repaired = try await ShaderGenerator.generate(
                prompt: prompt, feedback: "It failed to compile or was rejected by the fragment-only safety gate.")
            full = BuiltInShaders.prelude + "\n\n" + repaired
        }
        guard Self.isValidShader(full) else {
            throw AIError.unusable("The generated shader didn't compile — try rephrasing.")
        }
        return full
    }

    /// Generate an offline HTML wallpaper; one repair retry if it uses network or isn't a document.
    private func buildValidatedWeb(prompt: String) async throws -> String {
        var html = try await WebGenerator.generate(prompt: prompt)
        if !Self.isValidWeb(html) {
            html = try await WebGenerator.generate(
                prompt: prompt, feedback: "It used network/external resources or wasn't a complete offline HTML document.")
        }
        guard Self.isValidWeb(html) else {
            throw AIError.unusable("The generated page used network/external resources or wasn't valid — try rephrasing.")
        }
        return html
    }

    /// A shader is usable if it passes the fragment-only static gate AND actually compiles + renders.
    private static func isValidShader(_ source: String) -> Bool {
        do { try ShaderValidator.validate(source) } catch { return false }
        return ThumbnailRenderer.image(forShader: source) != nil
    }

    /// A web wallpaper is usable if it looks like an HTML document and uses NO network/eval — the
    /// caged renderer blocks those, so anything flagged would render broken.
    private static func isValidWeb(_ html: String) -> Bool {
        let lower = html.lowercased()
        guard lower.contains("<html") || lower.contains("<canvas") || lower.contains("<script") else { return false }
        return WebValidator.warnings(source: html, filename: "index.html").isEmpty
    }

    /// Export an installed wallpaper to a `.livewallpaper` the user can hand to someone else (P2P).
    private func exportWallpaper(_ id: String) {
        let title = model.title(forID: id)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "livewallpaper") ?? .data]
        panel.nameFieldStringValue = "\(title).livewallpaper"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.exportPackage(id: id, to: url) }
        catch { presentError("Could not export wallpaper", error) }
    }

    @objc private func quit() {
        for s in screenlets { s.renderer.stop() }
        NSApplication.shared.terminate(nil)
    }

    /// Put the user's real desktop picture back on any exit — the solid backdrop only makes sense
    /// while we're running (otherwise they'd be left with a blank coloured desktop).
    func applicationWillTerminate(_ notification: Notification) {
        DesktopBackground.restore()
    }

    /// Apply the neutral solid backdrop, or restore the user's wallpaper, per the preference.
    private func applyBackdropIfEnabled() {
        if Preferences.shared.solidBackdrop { DesktopBackground.apply() }
        else { DesktopBackground.restore() }
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
        // Rotation is a Premium feature — don't run it for free users even if the flag is set.
        guard Preferences.shared.rotationEnabled, Entitlement.shared.isPremium else { return }
        let interval = TimeInterval(max(1, Preferences.shared.rotationMinutes) * 60)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotate() }
        }
    }

    // MARK: - Schedule

    /// (Re)arm the time-of-day schedule. Premium-gated like rotation. Applies the currently-due
    /// wallpaper immediately, then ticks every 30s to catch each entry's time.
    private func restartSchedule() {
        scheduleTimer?.invalidate(); scheduleTimer = nil
        lastScheduleWallpaperID = nil
        guard Preferences.shared.scheduleEnabled, Entitlement.shared.isPremium,
              !Preferences.shared.scheduleEntries.isEmpty else { return }
        applyScheduleNow()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyScheduleNow() }
        }
    }

    /// Apply the wallpaper due at the current time of day, if it isn't already the one the schedule
    /// set. Skips missing/uninstalled ids so a stale entry never blanks the desktop.
    private func applyScheduleNow() {
        let minutes = WallpaperScheduleLogic.minutesOfDay(for: Date())
        guard let id = WallpaperScheduleLogic.activeWallpaperID(
                entries: Preferences.shared.scheduleEntries, minutesNow: minutes),
              id != lastScheduleWallpaperID,
              model.available.contains(where: { $0.id == id })
        else { return }
        lastScheduleWallpaperID = id
        activate(id)
    }

    /// Advance every display to *its own* next wallpaper, so monitors that started on different
    /// wallpapers keep rotating independently instead of snapping to one shared pick.
    private func rotate() {
        let ids = model.available.map(\.id)
        guard ids.count > 1 else { return }
        for screen in NSScreen.screens {
            let current = library.assignedID(for: screen, default: WallpaperCatalog.defaultID)
            let idx = ids.firstIndex(of: current) ?? -1
            library.assign(ids[(idx + 1) % ids.count], to: screen)
        }
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
}
