import AppKit
import SwiftUI

/// The in-app workshop browser (Explore tab): search + sort a grid of published wallpapers and
/// install any of them. Install hands the downloaded bundle to `Library.install` (via `onInstall`),
/// so checksum + shader-gate verification still apply.
struct WorkshopView: View {
    let client: WorkshopClient
    let onInstall: @MainActor (WorkshopItem) async -> String?

    @State private var items: [WorkshopItem] = []
    @State private var search = ""
    @State private var sort: WorkshopClient.Sort = .newest
    @State private var loading = false
    @State private var installing: Set<String> = []
    @State private var installed: Set<String> = []
    @State private var banner: String?

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if !WorkshopConfig.isConfigured {
                notConfigured
            } else {
                toolbar
                Divider()
                content
                if let banner {
                    Divider()
                    Text(banner).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { await load() }
    }

    private var toolbar: some View {
        HStack {
            TextField("Search wallpapers", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load() } }
            Picker("", selection: $sort) {
                ForEach(WorkshopClient.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            .onChange(of: sort) { Task { await load() } }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if loading {
            Spacer(); ProgressView(); Spacer()
        } else if items.isEmpty {
            Spacer(); Text("No wallpapers found.").foregroundStyle(.secondary); Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        WorkshopTile(item: item,
                                     installing: installing.contains(item.id),
                                     installed: installed.contains(item.id)) { install(item) }
                    }
                }
                .padding(16)
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

    private func install(_ item: WorkshopItem) {
        installing.insert(item.id)
        Task {
            let err = await onInstall(item)
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
    let onInstall: () -> Void

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
                    Button("Install") { onInstall() }.controlSize(.small).buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let url = item.thumbURL {
            AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
            placeholder: { PlaceholderThumb(seed: item.title, kind: item.type.rawValue) }
        } else {
            PlaceholderThumb(seed: item.title, kind: item.type.rawValue)
        }
    }
}
