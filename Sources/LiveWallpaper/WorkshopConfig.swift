import Foundation

/// Public workshop endpoint. This ships in the app and is public by design — the PocketBase
/// `wallpapers` collection's list/view API rule (`status = "published"`) is the actual guard, so no
/// key is needed to browse. Fill in your PocketBase host, e.g. "https://api.yourdomain.com".
enum WorkshopConfig {
    static let pocketBaseURL = "https://YOUR-POCKETBASE-HOST"

    /// False while the placeholder is unchanged — lets the UI show a friendly "not set up yet".
    static var isConfigured: Bool { !pocketBaseURL.contains("YOUR-POCKETBASE") }
}
