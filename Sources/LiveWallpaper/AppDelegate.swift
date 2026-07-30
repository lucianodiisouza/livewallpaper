import AppKit
import os

/// Wires the app together: one desktop window + renderer per screen, the Governor, the status-bar
/// menu, and the notifications that rebuild windows when the screen layout changes and that report
/// occlusion to the Governor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "AppDelegate")
    private let governor = Governor()

    private var statusItem: NSStatusItem?
    private var statusStateItem: NSMenuItem?

    /// One entry per screen.
    private struct Screenlet {
        let window: DesktopWindow
        let renderer: VideoRenderer
    }
    private var screenlets: [Screenlet] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        governor.onChange = { [weak self] directive in
            guard let self else { return }
            self.log.notice("Applying directive: \(directive.description, privacy: .public)")
            for s in self.screenlets { s.renderer.apply(directive) }
            self.updateStatusTitle(directive)
        }
        governor.start()

        rebuildScreenlets()

        // Rebuild the whole window set when monitors/resolutions/arrangement change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildScreenlets() }
        }

        // Occlusion: when a window becomes visible/covered, recompute whether *any* window is visible.
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

        for screen in NSScreen.screens {
            let window = DesktopWindow(screen: screen)
            let renderer = VideoRenderer()
            window.orderFront(nil)
            if let layer = window.renderLayer {
                renderer.start(in: layer)
            }
            renderer.apply(governor.current)
            screenlets.append(Screenlet(window: window, renderer: renderer))
        }
        log.notice("Built \(self.screenlets.count) desktop window(s).")
        reportOcclusion()
    }

    private func reportOcclusion() {
        // Visible if at least one wallpaper window is not fully covered.
        let anyVisible = screenlets.contains { $0.window.occlusionState.contains(.visible) }
        governor.setAnyWindowVisible(anyVisible)
    }

    // MARK: - Status bar

    private func setUpStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🖼️"
        status.button?.toolTip = "LiveWallpaper"

        let menu = NSMenu()
        let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveWallpaper", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        status.menu = menu

        self.statusItem = status
        self.statusStateItem = stateItem
    }

    private func updateStatusTitle(_ directive: RenderDirective) {
        statusStateItem?.title = "State: \(directive.description)"
        statusItem?.button?.title = directive.paused ? "🖼️⏸" : "🖼️"
    }

    @objc private func quit() {
        for s in screenlets { s.renderer.stop() }
        NSApplication.shared.terminate(nil)
    }
}
