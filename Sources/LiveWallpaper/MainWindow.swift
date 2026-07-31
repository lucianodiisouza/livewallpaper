import AppKit
import SwiftUI

/// The main app window: Installed / Explore / Settings. Opened from the menu bar's
/// "Open LiveWallpaper". Binds to the shared `AppModel`.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            InstalledView(model: model)
                .tabItem { Label("Installed", systemImage: "square.grid.2x2") }
            ExploreView(model: model)
                .tabItem { Label("Explore", systemImage: "safari") }
            SettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 620)
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

/// One wallpaper preview card in the Installed grid.
struct WallpaperTile: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.Entry
    @State private var thumb: NSImage?

    private var isActive: Bool { entry.id == model.currentID }
    private var isStarred: Bool { model.isStarred(entry.id) }

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
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Set") { model.setActive(entry.id) }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
                if !entry.isBuiltIn {
                    Button { model.remove(entry.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).controlSize(.small).help("Uninstall")
                }
            }
        }
        .task(id: entry.id) {
            if let src = entry.previewSource { thumb = ThumbnailRenderer.image(forShader: src) }
        }
    }

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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .topLeading) {
            if isActive {
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

// MARK: - Installed

struct InstalledView: View {
    @ObservedObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.available.count) wallpapers · pin up to \(AppModel.maxStars) ★ for the menu bar")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.onImport?() } label: { Label("Import…", systemImage: "plus") }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.available) { WallpaperTile(model: model, entry: $0) }
                }
                .padding(16)
            }
        }
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
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            }
            Section("Power") {
                Picker("On battery", selection: $prefs.batteryBehavior) {
                    ForEach(BatteryBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Wallpapers always pause when covered, on lock, or when the display sleeps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rotation") {
                Toggle("Rotate through all wallpapers", isOn: $prefs.rotationEnabled)
                Stepper("Every \(prefs.rotationMinutes) min", value: $prefs.rotationMinutes, in: 1...240)
                    .disabled(!prefs.rotationEnabled)
            }
            if let schema = model.schemas[model.currentID], !schema.isEmpty {
                Section("Parameters · \(model.title(forID: model.currentID))") {
                    WallpaperParamRows(model: model, schema: schema).id(model.currentID)
                }
            }
        }
        .formStyle(.grouped)
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
