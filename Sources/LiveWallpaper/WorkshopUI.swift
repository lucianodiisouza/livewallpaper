import AppKit
import SwiftUI

/// The in-app workshop browser (Explore tab): search + sort a grid of published wallpapers and
/// install any of them. Install hands the downloaded bundle to `Library.install` (via `onInstall`),
/// so checksum + shader-gate verification still apply.
struct WorkshopView: View {
    let client: WorkshopClient
    /// The shared app model — observed here so the rotation badges + free-for-period logic
    /// update when the active rotation flips (or when its end date passes).
    @ObservedObject var model: AppModel
    let onInstall: @MainActor (WorkshopItem) async -> String?
    /// Connected displays + a per-display install path — enables the "…" per-monitor menu.
    var screens: [AppModel.ScreenInfo] = []
    var onInstallToScreen: (@MainActor (WorkshopItem, String?) async -> String?)? = nil
    /// Called when a locked Premium item is tapped by a non-entitled user — opens the paywall.
    var onLocked: ((WorkshopItem) -> Void)? = nil
    /// Content checksums of packages already in the local library. A catalog item whose checksum is
    /// here is already installed (persists across launches), so its tile shows the installed state
    /// instead of an Install button.
    var installedChecksums: Set<String> = []
    @ObservedObject private var entitlement = Entitlement.shared

    @State private var items: [WorkshopItem] = []
    /// Top-5 by download count, shown in the Featured carousel. Loaded alongside the grid; failures
    /// are non-fatal — the grid still works without it.
    @State private var featured: [WorkshopItem] = []
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
                VStack(alignment: .leading, spacing: 24) {
                    if !featured.isEmpty {
                        FeaturedCarousel(items: featured,
                                         installing: installing,
                                         installed: { isInstalled($0) },
                                         locked: { $0.isPremium && !entitlement.isPremium && !model.rotationIDs.contains($0.id) },
                                         inRotation: { model.rotationIDs.contains($0.id) },
                                         screens: screens,
                                         onInstall: { item, key in
                            if item.isPremium && !entitlement.isPremium && !model.rotationIDs.contains(item.id) { onLocked?(item) }
                            else { install(item, toScreen: key) }
                        })
                        .padding(.top, 4)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("All Wallpapers")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 20)
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(items) { item in
                                WorkshopTile(item: item,
                                             installing: installing.contains(item.id),
                                             installed: isInstalled(item),
                                             locked: item.isPremium && !entitlement.isPremium,
                                             inRotation: model.rotationIDs.contains(item.id),
                                             screens: screens) { key in
                                    if item.isPremium && !entitlement.isPremium && !model.rotationIDs.contains(item.id) {
                                        onLocked?(item)
                                    } else { install(item, toScreen: key) }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
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
        // Fetch the grid and the Featured carousel in parallel. The carousel reuses the same call
        // shape with sort=.popular and a perPage=200 default; the client already memoises, so the
        // second hit to the same URL (within 60s) is free.
        async let catalog = client.fetchCatalog(search: search, sort: sort)
        async let top = (try? await client.fetchCatalog(search: "", sort: .popular)) ?? []
        do { items = try await catalog }
        catch { banner = error.localizedDescription }
        featured = Array(await top.prefix(5))
        loading = false
    }

    /// Already in the library? True for something installed this session or a prior one — the latter
    /// matched by content checksum (a catalog item's `checksum` equals its manifest checksum).
    private func isInstalled(_ item: WorkshopItem) -> Bool {
        installed.contains(item.id) || installedChecksums.contains(item.checksum)
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
    /// True for a Premium item when the user isn't entitled — install becomes an "Unlock" action.
    var locked: Bool = false
    /// True if the item is in the active rotation pool. Drives the "Free this period" badge and
    /// the install affordance (rotation items can be installed by anyone, even free users).
    var inRotation: Bool = false
    var screens: [AppModel.ScreenInfo] = []
    /// Install the item, then apply it to one display (key) or all (nil). For a locked item the
    /// parent intercepts this and opens the paywall instead of installing.
    let onInstall: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(height: 120).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if item.isPremium {
                        Label("Premium", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6)).foregroundStyle(.yellow)
                            .clipShape(Capsule()).padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if inRotation {
                        Label("Free this period", systemImage: "gift.fill")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.9)).foregroundStyle(.white)
                            .clipShape(Capsule()).padding(8)
                    }
                }
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
                } else if locked {
                    Button("Unlock") { onInstall(nil) }
                        .controlSize(.small).buttonStyle(.borderedProminent).tint(.yellow)
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

// MARK: - Featured carousel

/// Horizontally-scrolling row of wider featured cards (top 5 by install count), shown above the
/// main catalog grid. Each card is ~1.6× a regular tile's width with a "Featured" ribbon, the live
/// thumbnail, the install count, and an Install/Unlock/Installed action.
struct FeaturedCarousel: View {
    let items: [WorkshopItem]
    let installing: Set<String>
    let installed: (WorkshopItem) -> Bool
    let locked: (WorkshopItem) -> Bool
    let inRotation: (WorkshopItem) -> Bool
    let screens: [AppModel.ScreenInfo]
    let onInstall: (WorkshopItem, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Featured").font(.title3.weight(.semibold))
                Text("· Top by installs").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(items) { item in
                        FeaturedCard(item: item,
                                     installing: installing.contains(item.id),
                                     installed: installed(item),
                                     locked: locked(item),
                                     inRotation: inRotation(item),
                                     screens: screens,
                                     onInstall: onInstall)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// One wider featured card. Live preview (when shipped), title, type + install count, and the
/// same Install / Unlock / Installed states as a regular tile — so a user who acts on the
/// featured card doesn't need to learn a second pattern.
struct FeaturedCard: View {
    let item: WorkshopItem
    let installing: Bool
    let installed: Bool
    let locked: Bool
    let inRotation: Bool
    let screens: [AppModel.ScreenInfo]
    let onInstall: (WorkshopItem, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(width: 320, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    Label("Featured", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.55)).foregroundStyle(.white)
                        .clipShape(Capsule()).padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    if item.isPremium {
                        Label("Premium", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6)).foregroundStyle(.yellow)
                            .clipShape(Capsule()).padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if inRotation {
                        Label("Free this period", systemImage: "gift.fill")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.green.opacity(0.9)).foregroundStyle(.white)
                            .clipShape(Capsule()).padding(10)
                    }
                }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text("\(item.type.rawValue) · \(item.downloadCount) installs")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if installing {
                    ProgressView().controlSize(.small)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .help("Already installed")
                } else if locked {
                    Button("Unlock") { onInstall(item, nil) }
                        .controlSize(.small).buttonStyle(.borderedProminent).tint(.yellow)
                } else {
                    Button("Install") { onInstall(item, nil) }
                        .controlSize(.small).buttonStyle(.bordered)
                    if screens.count > 1 { perDisplayMenu }
                }
            }
        }
        .frame(width: 320)
    }

    private var perDisplayMenu: some View {
        Menu {
            Button("Install · all displays") { onInstall(item, nil) }
            Divider()
            ForEach(screens) { s in
                Button("Install · \(s.name)") { onInstall(item, s.id) }
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private var preview: some View {
        if item.thumbURL != nil { CachedThumb(item: item) }
        else { PlaceholderThumb(seed: item.title, kind: item.type.rawValue) }
    }
}
