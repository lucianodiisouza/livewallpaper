import AppKit
import SwiftUI

/// The in-app workshop browser: search + sort a list of published wallpapers and install any of
/// them. Install hands the downloaded bundle to `Library.install` (via the `onInstall` callback),
/// so checksum + shader-gate verification still apply.
struct WorkshopView: View {
    let client: WorkshopClient
    /// Returns nil on success, or an error message. Provided by AppDelegate (does download+install).
    let onInstall: @MainActor (WorkshopItem) async -> String?

    @State private var items: [WorkshopItem] = []
    @State private var search = ""
    @State private var sort: WorkshopClient.Sort = .newest
    @State private var loading = false
    @State private var installing: Set<String> = []
    @State private var banner: String?

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
                    Text(banner).font(.caption).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 540, height: 480)
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
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: sort) { Task { await load() } }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(8)
    }

    @ViewBuilder private var content: some View {
        if loading {
            Spacer(); ProgressView(); Spacer()
        } else if items.isEmpty {
            Spacer(); Text("No wallpapers found.").foregroundStyle(.secondary); Spacer()
        } else {
            List(items) { item in row(item) }
                .listStyle(.inset)
        }
    }

    private func row(_ item: WorkshopItem) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: item.thumbURL) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            .frame(width: 72, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium)
                Text("\(item.type.rawValue) · \(item.downloadCount) installs · \(item.authorHandle ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installing.contains(item.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") { install(item) }
            }
        }
        .padding(.vertical, 2)
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
            banner = err ?? "Installed “\(item.title)”."
            await load()   // refresh install counts
        }
    }
}

/// Hosts the workshop browser in a normal window (the app is otherwise a menu-bar accessory).
@MainActor
final class WorkshopWindowController {
    private var window: NSWindow?

    func show(client: WorkshopClient, onInstall: @escaping @MainActor (WorkshopItem) async -> String?) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: WorkshopView(client: client, onInstall: onInstall))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Workshop"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
