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
        var previewVideoURL: URL? = nil    // video file for a static frame preview (video only)
        /// Source files for a built-in or installed web wallpaper, used to snapshot a thumb when
        /// no `thumbnail.png` is shipped. Nil for non-web kinds.
        var previewWeb: WebPreviewSource? = nil
        /// A pre-rendered thumbnail shipped with the package (or bundled with the app). Used as the
        /// first-resort preview, ahead of any on-the-fly rendering.
        var thumbnailFileURL: URL? = nil
        var isShareable: Bool = false      // user-imported ⇒ P2P-shareable (catalog content isn't)
        var isPremium: Bool = false        // locked behind the Premium entitlement
    }

    /// Source files for a web wallpaper preview render.
    struct WebPreviewSource: Hashable, Sendable {
        let root: URL           // directory containing the entry file (or the bundle root for built-ins)
        let entry: String       // entry path relative to `root`
        let allowlist: [String] // network allowlist to honour while capturing
    }

    /// Drives the paywall sheet (nil ⇒ hidden). `reason` explains what the user tried to unlock.
    struct PaywallContext: Identifiable { let id = UUID(); let reason: String }

    /// What the AI generator should produce.
    enum GenerateKind: String, CaseIterable, Identifiable {
        case shader, web
        var id: String { rawValue }
        var label: String {
            switch self {
            case .shader: return String(localized: "ai.sheet.kind.shader")
            case .web: return String(localized: "ai.sheet.kind.web")
            }
        }
    }

    /// Live render state from the Governor, shown in the energy panel. `reason` explains why we're
    /// paused or throttled right now.
    struct RenderState: Equatable { var paused: Bool; var fps: Int; var reason: String }

    /// One physical display and what's assigned to it. `id` is the Library screen key.
    struct ScreenInfo: Identifiable {
        let id: String          // Library.key(for:) — stable NSScreenNumber string
        let name: String        // e.g. "Built-in Retina Display"
        let width: Int          // pixels
        let height: Int
        let frame: CGRect       // points, global coords — drives the to-scale arrangement drawing
        var assignedID: String  // wallpaper id currently rendering here
    }

    /// Everything available locally to use (built-ins + installed packages).
    @Published var available: [Entry] = []
    /// Content checksums of every installed package. The catalog (Explore) matches items against this
    /// (an item's `checksum` equals its manifest checksum, per the seed) to mark already-installed
    /// wallpapers as installed across launches — not just ones installed in the current session.
    @Published var installedChecksums: Set<String> = []
    /// Wallpaper ids in the current rotation pool — Premium items temporarily free for everyone.
    /// Driven by the backoffice; the client just reads it. Empty when rotation is off.
    @Published private(set) var rotationIDs: Set<String> = []
    /// Headline the operator set for the active rotation (e.g. "Black Friday picks"). Empty when
    /// rotation is off — callers fall back to default copy ("Free this period").
    @Published private(set) var rotationHeadline: String = ""
    /// When the active rotation ends. `nil` when rotation is off.
    @Published private(set) var rotationEndsAt: Date?
    /// Connected displays + per-screen assignment (drives the in-Installed monitor strip).
    @Published var screens: [ScreenInfo] = []
    /// The currently-rendering wallpaper id.
    @Published var currentID: String = ""
    /// Live render state (paused/fps + reason) mirrored from the Governor for the energy panel.
    @Published var renderState = RenderState(paused: false, fps: 60, reason: "Running at full frame rate")
    /// When non-nil, the paywall sheet is shown with this context.
    @Published var paywall: PaywallContext?
    /// True while an AI wallpaper is being generated.
    @Published var isGenerating = false
    /// Last AI-generation error (nil on success).
    @Published var aiError: String?
    /// Pinned wallpaper ids shown in the menu bar (max 5, ordered).
    @Published private(set) var starred: [String] = []

    /// Per-wallpaper parameter schema (empty if none).
    var schemas: [String: [ConfigParameter]] = [:]

    let workshop = WorkshopClient()

    // Wired by AppDelegate:
    var onSetActive: ((String) -> Void)?
    /// Assign one wallpaper to a single display: (wallpaperID, screenKey).
    var onAssign: ((String, String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onImport: (() -> Void)?
    /// Export an installed package to a `.livewallpaper` (opens a save panel) for peer-to-peer sharing.
    var onExport: ((String) -> Void)?
    /// Build a fresh, standalone renderer for a wallpaper id — used to render the live preview sheet.
    var makePreviewRenderer: ((String) -> (any WallpaperRenderer)?)?
    /// Generate a wallpaper (shader or web) from a natural-language prompt (Premium).
    var onGenerate: ((String, GenerateKind) -> Void)?
    var onStarsChanged: (() -> Void)?
    var onInstall: ((WorkshopItem) async -> String?)?
    /// Install a workshop item, then assign it to one display (nil ⇒ all). Returns an error string.
    var onInstallToScreen: ((WorkshopItem, String?) async -> String?)?
    var configFor: ((String) -> [String: ConfigValue])?
    var onApplyConfig: ((String, [String: ConfigValue]) -> Void)?
    /// Present the first-run onboarding walkthrough (also used by Settings → "Show welcome again").
    var onShowOnboarding: (() -> Void)?

    private let starKey = "starredIDs"
    static let maxStars = 5

    init() { starred = UserDefaults.standard.stringArray(forKey: starKey) ?? [] }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
    }

    func title(forID id: String) -> String { available.first { $0.id == id }?.title ?? id }

    // MARK: - Rotation

    /// Pull the current rotation from the backend. Idempotent; called on launch + when Settings
    /// tells us the entitlement changed. Failures are silent — the rotation pool is opt-in and
    /// the UI simply doesn't surface the badge if the backend is unreachable.
    func refreshRotation() async {
        guard let r = await workshop.fetchRotation() else {
            rotationIDs = []; rotationHeadline = ""; rotationEndsAt = nil; return
        }
        rotationIDs = Set(r.items.map(\.id))
        rotationHeadline = r.headline
        rotationEndsAt = r.endsAt
    }

    /// Is `id` currently in the active rotation pool? Premium items in the pool are free for
    /// everyone (including free members) until `rotationEndsAt`.
    func isInRotation(_ id: String) -> Bool { rotationIDs.contains(id) }

    // MARK: - Actions

    func setActive(_ id: String) {
        currentID = id
        onSetActive?(id)
    }

    /// Assign a wallpaper to a single display (leaves other screens untouched).
    func assign(_ wallpaperID: String, toScreen key: String) {
        onAssign?(wallpaperID, key)
    }

    // MARK: - Premium gating

    /// Apply a wallpaper, but if it's Premium and the user isn't entitled, open the paywall instead.
    /// `key` = a display to target (nil ⇒ all). Returns true if applied, false if the paywall opened.
    /// Items in the active rotation pool are an exception: they're free for everyone for the
    /// rotation window, so we let the apply through even when the user isn't Premium.
    @discardableResult
    func attemptApply(_ entry: Entry, toScreen key: String? = nil) -> Bool {
        if entry.isPremium && !Entitlement.shared.isPremium && !isInRotation(entry.id) {
            paywall = PaywallContext(reason: "“\(entry.title)” is a Premium wallpaper.")
            return false
        }
        if let key { assign(entry.id, toScreen: key) } else { setActive(entry.id) }
        return true
    }

    /// Open the paywall with a custom reason (e.g. a gated setting).
    func showPaywall(_ reason: String) { paywall = PaywallContext(reason: reason) }

    /// Kick off AI generation for `prompt` (Premium; gated in AppDelegate).
    func generate(_ prompt: String, kind: GenerateKind) { onGenerate?(prompt, kind) }

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
