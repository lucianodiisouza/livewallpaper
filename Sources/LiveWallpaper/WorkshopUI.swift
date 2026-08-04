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
            .navigationSubtitle(WorkshopConfig.isConfigured
                                 ? String(format: String(localized: "tab.catalog.subtitle", bundle: .main), items.count)
                                 : "")
            .searchable(text: $search, prompt: String(localized: "tab.catalog.searchPrompt", bundle: .main))
            .toolbar {
                if WorkshopConfig.isConfigured {
                    ToolbarItem(placement: .primaryAction) {
                        Picker(LocalizedStringKey("workshop.sort.label"), selection: $sort) {
                            ForEach(WorkshopClient.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                            .help(LocalizedStringKey("workshop.help.refresh"))
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
            VStack { Spacer(); Text(LocalizedStringKey("workshop.empty")).foregroundStyle(.secondary); Spacer() }
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
                        Text(LocalizedStringKey("workshop.section.all"))
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
            Text(LocalizedStringKey("workshop.notConfigured.title")).font(.headline)
            Text(LocalizedStringKey("workshop.notConfigured.body"))
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
            banner = err ?? String(format: String(localized: "workshop.banner.installed", bundle: .main), item.title)
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
                        Label(LocalizedStringKey("tab.catalog.premiumBadge"), systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6)).foregroundStyle(.yellow)
                            .clipShape(Capsule()).padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if inRotation {
                        Label(LocalizedStringKey("tab.catalog.freeThisPeriod"), systemImage: "gift.fill")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.9)).foregroundStyle(.white)
                            .clipShape(Capsule()).padding(8)
                    }
                }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(String(format: String(localized: "workshop.installs", bundle: .main), item.type.rawValue, item.downloadCount))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if installing {
                    ProgressView().controlSize(.small)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if locked {
                    Button(LocalizedStringKey("workshop.action.unlock")) { onInstall(nil) }
                        .controlSize(.small).buttonStyle(.glassProminent).tint(.yellow)
                } else {
                    Button(LocalizedStringKey("workshop.action.install")) { onInstall(nil) }.controlSize(.small).buttonStyle(.glass)
                    if screens.count > 1 { perDisplayMenu }
                }
            }
        }
    }

    /// Install straight onto one named display (or all).
    private var perDisplayMenu: some View {
        Menu {
            Button(LocalizedStringKey("workshop.menu.all")) { onInstall(nil) }
            Divider()
            ForEach(screens) { s in
                Button(String(format: String(localized: "workshop.menu.perDisplay", bundle: .main), s.name)) { onInstall(s.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(LocalizedStringKey("workshop.menu.help"))
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

/// Full-width, one-card-at-a-time paged carousel of featured wallpapers (top 5 by installs), shown
/// above the main catalog grid. The card spans the carousel's own width, auto-advances every 6s,
/// pauses while the user is interacting, and shows a page-indicator strip ("ball markers") below
/// so the user always knows where they are in the rotation.
struct FeaturedCarousel: View {
    let items: [WorkshopItem]
    let installing: Set<String>
    let installed: (WorkshopItem) -> Bool
    let locked: (WorkshopItem) -> Bool
    let inRotation: (WorkshopItem) -> Bool
    let screens: [AppModel.ScreenInfo]
    let onInstall: (WorkshopItem, String?) -> Void

    /// Auto-advance interval. Long enough to read the title + count, short enough to feel alive.
    private let autoAdvanceSeconds: TimeInterval = 6

    @State private var currentIndex: Int = 0
    /// Mirror of the ScrollView's `scrollPosition` — keeps `currentIndex` in sync with manual swipes
    /// (programmatic jumps use `proxy.scrollTo`, which doesn't round-trip through this binding).
    @State private var scrolledID: Int? = nil
    /// Set briefly when the user touches the pager; suppresses auto-advance so the rotation respects
    /// the manual swipe. Re-arms 4s after the last interaction.
    @State private var userInteracting: Bool = false
    /// Inner width of the carousel row, measured via a non-layout background probe. Drives the card
    /// size *and* the explicit row height — a plain `GeometryReader` can't do the latter because it
    /// has no intrinsic height, so inside the vertical ScrollView it collapses and the cards spill
    /// over the grid below.
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(LocalizedStringKey("workshop.featured")).font(.title3.weight(.semibold))
                Text(LocalizedStringKey("workshop.featured.subtitle")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)

            // A fixed-height hero band — NOT a full-width 16:9 card. On a wide window a full-width
            // 16:9 card is ~1000pt tall and swallows the whole view; a featured strip should be a
            // short, wide band. Height scales gently with width but is clamped so it never dominates.
            let bandHeight = min(max(230, rowWidth * 0.32), 340)
            // Full-bleed carousel: one card fills the row, no peek of the neighbour. The arrow
            // buttons are the affordance for "there's more" — touchpad scroll works too, but
            // without the peek the arrows are what makes navigation discoverable.
            let cardWidth = rowWidth

            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                FeaturedCard(item: item,
                                             installing: installing.contains(item.id),
                                             installed: installed(item),
                                             locked: locked(item),
                                             inRotation: inRotation(item),
                                             screens: screens,
                                             onInstall: onInstall)
                                .frame(width: cardWidth, height: bandHeight)
                                .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    // Paging (not view-aligned) so each card snaps to the full row width and the
                    // adjacent card stays entirely off-screen — no peek.
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $scrolledID)       // mirrors manual swipes back to currentIndex
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { _ in userInteracting = true }
                    )
                    // Programmatic jumps (auto-advance, dot tap, arrow tap) → scroll. Manual swipes
                    // flow back through scrollPosition → currentIndex, so the dots and the page
                    // stay in sync.
                    .onChange(of: currentIndex) { _, new in
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(new, anchor: .leading)
                        }
                    }
                    .onChange(of: scrolledID) { _, new in
                        if let new, new != currentIndex { currentIndex = new }
                    }
                    .onAppear {
                        proxy.scrollTo(currentIndex, anchor: .leading)
                    }

                    // Side arrow buttons. Always rendered (the user asked for an obvious
                    // affordance), but disabled at the ends so they don't promise a page that
                    // doesn't exist. Sit in a vertical center on top of the card.
                    CarouselArrow(side: .left) {
                        userInteracting = true
                        withAnimation(.easeInOut(duration: 0.35)) {
                            currentIndex = max(0, currentIndex - 1)
                        }
                    }
                    .disabled(currentIndex == 0)
                    .opacity(currentIndex == 0 ? 0.35 : 1)

                    CarouselArrow(side: .right) {
                        userInteracting = true
                        withAnimation(.easeInOut(duration: 0.35)) {
                            currentIndex = min(items.count - 1, currentIndex + 1)
                        }
                    }
                    .disabled(currentIndex >= items.count - 1)
                    .opacity(currentIndex >= items.count - 1 ? 0.35 : 1)
                }
            }
            // Pin the row to the band height so the vertical stack reserves the space — without this
            // the carousel drew on top of the "All Wallpapers" grid. Top padding gives the card's
            // shadow room to breathe so it isn't clipped at the top.
            .frame(height: bandHeight)
            .padding(.top, 2)
            // Non-layout width probe: reports the row's inner width without stealing height the way
            // a wrapping GeometryReader would.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { rowWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in rowWidth = w }
                }
            )
            .padding(.horizontal, 20)
            .modifier(CarouselHeight(autoAdvanceSeconds: autoAdvanceSeconds,
                                     count: items.count,
                                     currentIndex: $currentIndex,
                                     userInteracting: $userInteracting))

            // Page-indicator dots ("ball markers"). One per featured item; the current one is
            // tinted, the rest are secondary. Tapping a dot jumps the pager to that card.
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, _ in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { currentIndex = index }
                        userInteracting = true
                    } label: {
                        Circle()
                            .fill(index == currentIndex ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help(items[index].title)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }
}

/// Side navigation arrow for the Featured carousel. Circular, semi-transparent, sits centred
/// vertically on the card. Always rendered so the affordance is discoverable; the parent
/// disables + dims it at the carousel ends.
private struct CarouselArrow: View {
    enum Side { case left, right }
    let side: Side
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: side == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(side == .left ? String(localized: "workshop.carousel.prev", bundle: .main)
                            : String(localized: "workshop.carousel.next", bundle: .main))
        .accessibilityLabel(side == .left ? String(localized: "workshop.carousel.a11y.prev", bundle: .main)
                                       : String(localized: "workshop.carousel.a11y.next", bundle: .main))
        .padding(side == .left ? .leading : .trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .left ? .leading : .trailing)
    }
}

/// Drives the Featured carousel's auto-advance timer and re-arms it after the user stops
/// interacting. Lives in a `ViewModifier` so the parent body stays readable.
private struct CarouselHeight: ViewModifier {
    let autoAdvanceSeconds: TimeInterval
    let count: Int
    @Binding var currentIndex: Int
    @Binding var userInteracting: Bool
    @State private var rearmTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task(id: count) {
                guard count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(autoAdvanceSeconds * 1_000_000_000))
                    if Task.isCancelled { return }
                    if !userInteracting && count > 1 {
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                currentIndex = (currentIndex + 1) % count
                            }
                        }
                    }
                }
            }
            .onChange(of: userInteracting) { interacting in
                rearmTask?.cancel()
                guard interacting else { return }
                // Re-arm userInteracting=false 4s after the last interaction so auto-advance resumes.
                rearmTask = Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if !Task.isCancelled { await MainActor.run { userInteracting = false } }
                }
            }
    }
}

/// One full-width featured card. Live preview (when shipped) sized to the carousel's 16:9 area,
/// title, type + install count, and the same Install / Unlock / Installed states as a regular tile
/// — so a user who acts on the featured card doesn't need to learn a second pattern.
struct FeaturedCard: View {
    let item: WorkshopItem
    let installing: Bool
    let installed: Bool
    let locked: Bool
    let inRotation: Bool
    let screens: [AppModel.ScreenInfo]
    let onInstall: (WorkshopItem, String?) -> Void

    var body: some View {
        // The whole card is the preview image; text and actions sit *on* it over a bottom scrim.
        // This reads far more "featured/hero" than an image with a separate label row below it, and
        // fills the fixed band height cleanly with no cropped title.
        ZStack(alignment: .bottom) {
            // A definite-size box the image fills into. `preview` uses aspectRatio(.fill), which is
            // greedy vertically — placed directly in the ZStack it inflates the card past bandHeight
            // and the ScrollView clips the top (badge) and bottom (title). Hosting it as an overlay
            // on a greedy Color pins the card to bandHeight and crops the *image* instead.
            Color.black.opacity(0.25)
                .overlay { preview }
                .clipped()

            // Bottom scrim so white text stays legible over any preview.
            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)

            // Title + meta on the left, the action on the right — anchored to the bottom.
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1)
                    Text(String(format: String(localized: "workshop.installs", bundle: .main), item.type.rawValue, item.downloadCount))
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 8)
                action
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the card's fixed band frame
        .background(Color.black.opacity(0.2))   // fallback behind a transparent preview
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            Label(LocalizedStringKey("tab.catalog.featured.ribbon"), systemImage: "sparkles")
                .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white).padding(12)
        }
        .overlay(alignment: .topTrailing) {
            if inRotation {
                badge(String(localized: "tab.catalog.freeThisPeriod", bundle: .main), "gift.fill", .green.opacity(0.9), .white)
            } else if item.isPremium {
                badge(String(localized: "tab.catalog.premiumBadge", bundle: .main), "lock.fill", .black.opacity(0.55), .yellow)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    private func badge(_ text: String, _ icon: String, _ bg: Color, _ fg: Color) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon).font(.caption2.weight(.bold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(bg, in: Capsule()).foregroundStyle(fg).padding(12)
    }

    @ViewBuilder private var action: some View {
        if installing {
            ProgressView().controlSize(.small).tint(.white)
        } else if installed {
            Label(LocalizedStringKey("workshop.badge.installed"), systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        } else if locked {
            Button(LocalizedStringKey("workshop.action.unlock")) { onInstall(item, nil) }
                .controlSize(.large).buttonStyle(.glassProminent).tint(.yellow)
        } else {
            HStack(spacing: 6) {
                Button(LocalizedStringKey("workshop.action.install")) { onInstall(item, nil) }
                    .controlSize(.large).buttonStyle(.glassProminent)
                if screens.count > 1 { perDisplayMenu }
            }
        }
    }

    private var perDisplayMenu: some View {
        Menu {
            Button(LocalizedStringKey("workshop.menu.all")) { onInstall(item, nil) }
            Divider()
            ForEach(screens) { s in
                Button(String(format: String(localized: "workshop.menu.perDisplay", bundle: .main), s.name)) { onInstall(item, s.id) }
            }
        } label: { Image(systemName: "ellipsis.circle.fill").foregroundStyle(.white) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private var preview: some View {
        if item.thumbURL != nil { CachedThumb(item: item) }
        else { PlaceholderThumb(seed: item.title, kind: item.type.rawValue) }
    }
}
