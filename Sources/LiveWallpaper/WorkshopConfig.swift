import Foundation

/// Public workshop endpoint — the PocketBase catalog hosted on Railway. Ships in the app and is
/// public by design: the `wallpapers` collection's list/view rule (`status = "published"`) is the
/// actual guard, so no key is needed to browse. Bundle files themselves are served from R2 (their
/// full URLs come back in each record). Set this to your Railway PocketBase URL.
/// Backend infra lives in the separate `livewallpaper-workshop` repo.
enum WorkshopConfig {
    static let pocketBaseURL = "https://YOUR-POCKETBASE-HOST"

    /// False while the placeholder is unchanged — lets the UI show a friendly "not set up yet".
    static var isConfigured: Bool { !pocketBaseURL.contains("YOUR-POCKETBASE") }
}
