import AppKit
import SwiftUI

/// The main app window: Installed / Explore / Settings. Opened from the menu bar's
/// "Open LiveWallpaper". Binds to the shared `AppModel`.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            InstalledView(model: model)
                .tabItem { Label("Installed", systemImage: "square.stack.3d.up") }
            ExploreView(model: model)
                .tabItem { Label("Explore", systemImage: "safari") }
            SettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 560)
    }
}

// MARK: - Installed

struct InstalledView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.available.count) wallpapers · pin up to \(AppModel.maxStars) ★ for the menu bar")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.onImport?() } label: { Label("Import…", systemImage: "plus") }
            }
            .padding(8)
            Divider()
            List(model.available) { e in row(e) }
                .listStyle(.inset)
        }
    }

    private func row(_ e: AppModel.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(e.kind)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).fontWeight(e.id == model.currentID ? .semibold : .regular)
                    if e.id == model.currentID {
                        Text("ACTIVE").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.2)).foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(e.isBuiltIn ? "built-in · \(e.kind)" : e.kind)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.toggleStar(e.id) } label: {
                Image(systemName: model.isStarred(e.id) ? "star.fill" : "star")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isStarred(e.id) ? .yellow : .secondary)
            .disabled(!model.isStarred(e.id) && !model.canStarMore)
            .help(model.isStarred(e.id) ? "Unpin from menu bar"
                  : (model.canStarMore ? "Pin to menu bar" : "Menu bar list is full (\(AppModel.maxStars))"))

            if e.id == model.currentID {
                Text("Active").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Set") { model.setActive(e.id) }
            }
            if !e.isBuiltIn {
                Button(role: .destructive) { model.remove(e.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.red).help("Uninstall")
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ kind: String) -> String {
        switch kind { case "video": return "film"; case "web": return "globe"; default: return "sparkles" }
    }
}

// MARK: - Explore (the workshop)

struct ExploreView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        WorkshopView(client: model.workshop) { item in
            await model.onInstall?(item) ?? "Install unavailable."
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PreferencesView(prefs: .shared)
                if let schema = model.schemas[model.currentID], !schema.isEmpty {
                    Divider()
                    WallpaperParams(model: model, schema: schema)
                        .id(model.currentID)   // recreate the store when the active wallpaper changes
                }
            }
        }
    }
}

/// Parameter controls for the active wallpaper, backed by a `ConfigStore`.
struct WallpaperParams: View {
    @StateObject private var store: ConfigStore
    private let title: String

    init(model: AppModel, schema: [ConfigParameter]) {
        let id = model.currentID
        let values = model.configFor?(id) ?? .defaults(for: schema)
        let s = ConfigStore(schema: schema, values: values)
        s.onChange = { [weak model] vals in model?.onApplyConfig?(id, vals) }
        _store = StateObject(wrappedValue: s)
        title = model.title(forID: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parameters · \(title)").font(.headline).padding(.horizontal).padding(.top, 8)
            ConfigForm(store: store)
        }
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
        let hosting = NSHostingController(rootView: MainView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "LiveWallpaper"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
