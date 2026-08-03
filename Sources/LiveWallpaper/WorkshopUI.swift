import AppKit
import SwiftUI

/// The in-app workshop browser (Explore tab): search + sort a grid of published wallpapers and
/// install any of them. Install hands the downloaded bundle to `Library.install` (via `onInstall`),
/// so checksum + shader-gate verification still apply.
struct WorkshopView: View {
    let client: WorkshopClient
    let onInstall: @MainActor (WorkshopItem) async -> String?
    /// Connected displays + a per-display install path — enables the "…" per-monitor menu.
    var screens: [AppModel.ScreenInfo] = []
    var onInstallToScreen: (@MainActor (WorkshopItem, String?) async -> String?)? = nil

    @State private var items: [WorkshopItem] = []
    @State private var search = ""
    @State private var sort: WorkshopClient.Sort = .newest
    @State private var loading = false
    @State private var installing: Set<String> = []
    @State private var installed: Set<String> = []
    @State private var banner: String?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 18)]

    var body: some View {
        content
            .navigationSubtitle(WorkshopConfig.isConfigured ? "\(items.count) wallpapers" : "")
            .searchable(text: $search, prompt: "Search wallpapers")
            .toolbar {
                if WorkshopConfig.isConfigured {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Sort", selection: $sort) {
                            ForEach(WorkshopClient.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh")
                    }
                }
            }
            .onSubmit(of: .search) { Task { await load() } }
            .onChange(of: search) { if search.isEmpty { Task { await load() } } }
            .onChange(of: sort) { Task { await load() } }
            .task { await load() }
            .safeAreaInset(edge: .bottom) {
                if let banner {
                    Text(banner).font(.caption).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !WorkshopConfig.isConfigured {
            notConfigured
        } else if loading {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            VStack { Spacer(); Text("No wallpapers found.").foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        WorkshopTile(item: item,
                                     installing: installing.contains(item.id),
                                     installed: installed.contains(item.id),
                                     screens: screens) { key in install(item, toScreen: key) }
                    }
                }
                .padding(20)
            }
        }
    }

    private var notConfigured: some View {
        VStack(spacing: 8) {
            Image(systemName: "cloud").font(.largeTitle).foregroundStyle(.secondary)
            Text("Workshop not set up yet").font(.headline)
            Text("Set WorkshopConfig.pocketBaseURL to your PocketBase host. See docs/M4_PLAN.md.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func load() async {
        loading = true; banner = nil
        do { items = try await client.fetchCatalog(search: search, sort: sort) }
        catch { banner = error.localizedDescription }
        loading = false
    }

    private func install(_ item: WorkshopItem, toScreen key: String? = nil) {
        installing.insert(item.id)
        Task {
            let err: String?
            if let key, let onInstallToScreen { err = await onInstallToScreen(item, key) }
            else { err = await onInstall(item) }
            installing.remove(item.id)
            if err == nil { installed.insert(item.id) }
            banner = err ?? "Installed “\(item.title)”."
            await load()
        }
    }
}

/// One remote wallpaper card in the Explore grid.
struct WorkshopTile: View {
    let item: WorkshopItem
    let installing: Bool
    let installed: Bool
    var screens: [AppModel.ScreenInfo] = []
    /// Install the item, then apply it to one display (key) or all (nil).
    let onInstall: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(height: 120).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(item.type.rawValue) · \(item.downloadCount) installs")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if installing {
                    ProgressView().controlSize(.small)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Install") { onInstall(nil) }.controlSize(.small).buttonStyle(.bordered)
                    if screens.count > 1 { perDisplayMenu }
                }
            }
        }
    }

    /// Install straight onto one named display (or all).
    private var perDisplayMenu: some View {
        Menu {
            Button("Install · all displays") { onInstall(nil) }
            Divider()
            ForEach(screens) { s in
                Button("Install · \(s.name)") { onInstall(s.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Install and apply to a specific display")
    }

    @ViewBuilder private var preview: some View {
        if item.thumbURL != nil {
            CachedThumb(item: item)
        } else {
            PlaceholderThumb(seed: item.title, kind: item.type.rawValue)
        }
    }
}

/// A thumbnail backed by `WorkshopCache` instead of `AsyncImage`, so scrolling the grid serves
/// repeat views from memory/disk rather than refetching from R2. Falls back to the generated
/// placeholder while loading and if the fetch ultimately fails.
struct CachedThumb: View {
    let item: WorkshopItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                PlaceholderThumb(seed: item.title, kind: item.type.rawValue)
            }
        }
        .task(id: item.id) {
            if image == nil { image = await WorkshopCache.shared.thumbnail(for: item) }
        }
    }
}
