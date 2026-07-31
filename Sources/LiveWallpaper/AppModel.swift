import AppKit

/// UI-facing state shared by the main window (Installed/Explore/Settings tabs) and the menu bar.
/// AppDelegate owns rendering; it populates this model and wires the callbacks that actually act
/// (set active wallpaper, install, remove, apply parameters). SwiftUI views observe it.
@MainActor
final class AppModel: ObservableObject {

    struct Entry: Identifiable, Hashable {
        let id: String
        let title: String
        let kind: String        // video | metal | web
        let isBuiltIn: Bool
        var previewSource: String? = nil   // shader source for the preview thumbnail (metal only)
    }

    /// Everything available locally to use (built-ins + installed packages).
    @Published var available: [Entry] = []
    /// The currently-rendering wallpaper id.
    @Published var currentID: String = ""
    /// Pinned wallpaper ids shown in the menu bar (max 5, ordered).
    @Published private(set) var starred: [String] = []

    /// Per-wallpaper parameter schema (empty if none).
    var schemas: [String: [ConfigParameter]] = [:]

    let workshop = WorkshopClient()

    // Wired by AppDelegate:
    var onSetActive: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onImport: (() -> Void)?
    var onStarsChanged: (() -> Void)?
    var onInstall: ((WorkshopItem) async -> String?)?
    var configFor: ((String) -> [String: ConfigValue])?
    var onApplyConfig: ((String, [String: ConfigValue]) -> Void)?

    private let starKey = "starredIDs"
    static let maxStars = 5

    init() { starred = UserDefaults.standard.stringArray(forKey: starKey) ?? [] }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
    }

    func title(forID id: String) -> String { available.first { $0.id == id }?.title ?? id }

    // MARK: - Actions

    func setActive(_ id: String) {
        currentID = id
        onSetActive?(id)
    }

    func remove(_ id: String) {
        onRemove?(id)
        if let i = starred.firstIndex(of: id) { starred.remove(at: i); persistStars() }
    }

    // MARK: - Stars

    func isStarred(_ id: String) -> Bool { starred.contains(id) }
    var canStarMore: Bool { starred.count < Self.maxStars }

    func toggleStar(_ id: String) {
        if let i = starred.firstIndex(of: id) {
            starred.remove(at: i)
        } else if starred.count < Self.maxStars {
            starred.append(id)
        } else {
            return
        }
        persistStars()
        onStarsChanged?()
    }

    /// Drop stars that no longer point at an available wallpaper (e.g. after uninstall).
    func pruneStars() {
        let ids = Set(available.map(\.id))
        let kept = starred.filter { ids.contains($0) }
        if kept != starred { starred = kept; persistStars() }
    }

    private func persistStars() { UserDefaults.standard.set(starred, forKey: starKey) }

    /// The wallpapers shown in the menu bar (max 5, never empty): the starred set if any, otherwise
    /// the active one plus the next few available.
    func menuEntries() -> [Entry] {
        if available.count <= Self.maxStars { return available }
        let pinned = available.filter { starred.contains($0.id) }
        if !pinned.isEmpty { return pinned }
        // No stars yet: show the active wallpaper first, then fill up to the cap.
        let active = available.filter { $0.id == currentID }
        let rest = available.filter { $0.id != currentID }.prefix(Self.maxStars - active.count)
        return active + rest
    }
}
