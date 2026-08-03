import AppKit
import SwiftUI

/// First-run onboarding: a short, skippable walkthrough shown once on first launch (and re-runnable
/// from Settings → "Show welcome again"). Four steps — welcome, pick a first wallpaper, the
/// multi-monitor/rotation story, and a Premium mention — then it hands off to the main window.
///
/// Completion is tracked by `Preferences.hasCompletedOnboarding`; closing the window any way (Get
/// Started, Skip, or the red button) counts as done, so it never re-nags.
enum Onboarding {
    static let completedKey = "hasCompletedOnboarding"

    /// The wallpapers offered as a first pick: free built-ins only. Premium (locked) wallpapers and
    /// user-imported packages are excluded so the very first choice always applies cleanly.
    static func firstPicks(from entries: [AppModel.Entry], limit: Int = 6) -> [AppModel.Entry] {
        Array(entries.filter { $0.isBuiltIn && !$0.isPremium }.prefix(limit))
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    /// Close the onboarding window; `openMain == true` also brings up the main window (Get Started).
    var dismiss: (_ openMain: Bool) -> Void

    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable { case welcome, pick, displays, premium }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .pick: PickStep(model: model)
                case .displays: DisplaysStep()
                case .premium: PremiumStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        HStack {
            Spacer()
            Button("Skip") { dismiss(false) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Skip the intro — you can reopen it from Settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Back") { advance(-1) }
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)

            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()

            if step == .premium {
                Button("Get Started") { dismiss(true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { advance(1) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func advance(_ delta: Int) {
        let next = step.rawValue + delta
        guard let s = Step(rawValue: next) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { step = s }
    }
}

// MARK: - Steps

/// Shared scaffold: a big glyph, a title, a subtitle, and free-form content below.
private struct StepScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            PrismGlyph(size: 52).padding(.top, 8)
                .overlay(alignment: .center) {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            content
        }
        .padding(24)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        StepScaffold(symbol: "sparkles",
                     title: "Welcome to Primo Engine",
                     subtitle: "Live wallpapers for your Mac — Metal shaders, web animations, and video — built to be native and easy on your battery.") {
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow("bolt.fill", "Pauses when covered",
                           "Rendering drops to near-zero GPU whenever the wallpaper can't be seen.")
                FeatureRow("cpu", "Native, no Chromium",
                           "Pure Swift, Metal, and WebKit — not an Electron shell.")
                FeatureRow("square.stack.3d.up.fill", "Shaders, web & video",
                           "Tiny, GPU-native wallpapers you can't get from a video-only app.")
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct PickStep: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: String?

    private var picks: [AppModel.Entry] { Onboarding.firstPicks(from: model.available) }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        StepScaffold(symbol: "wand.and.stars",
                     title: "Pick your first wallpaper",
                     subtitle: "Tap one to try it live on your desktop right now. You can change it any time.") {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(picks) { entry in
                        OnboardingPickTile(entry: entry, isSelected: selectedID == entry.id) {
                            model.setActive(entry.id)
                            selectedID = entry.id
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
            }
            .frame(maxWidth: 460)
        }
        // Reflect whatever is already active (e.g. re-running onboarding) as the selection.
        .onAppear { if selectedID == nil { selectedID = model.currentID } }
    }
}

private struct OnboardingPickTile: View {
    let entry: AppModel.Entry
    let isSelected: Bool
    let onTap: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    PlaceholderThumb(seed: entry.title, kind: entry.kind)
                }
            }
            .frame(height: 84).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(5)
                }
            }
            Text(entry.title).font(.caption).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: entry.id) { thumb = await loadThumb(entry) }
    }
}

private struct DisplaysStep: View {
    var body: some View {
        StepScaffold(symbol: "display.2",
                     title: "One app, every display",
                     subtitle: "Give each monitor its own wallpaper, or the same one everywhere — you're in control.") {
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow("rectangle.on.rectangle", "Per-display wallpapers",
                           "A to-scale monitor strip lets you target any screen and set it independently.")
                FeatureRow("arrow.triangle.2.circlepath", "Rotation & playlists",
                           "Cycle through your wallpapers automatically — each display on its own. (Premium)")
                FeatureRow("moon.zzz.fill", "Battery-aware",
                           "Choose what happens on battery: pause, throttle, or keep full speed.")
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct PremiumStep: View {
    var body: some View {
        StepScaffold(symbol: "checkmark.seal.fill",
                     title: "Free to use — Premium when you want more",
                     subtitle: "The core app is free. Premium unlocks the full catalog and the marquee features, one time — no subscription.") {
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow("square.stack", "The full wallpaper catalog", "Every curated shader, web, and video wallpaper.")
                FeatureRow("wand.and.stars", "AI-generated wallpapers", "Describe a look and generate a live wallpaper of your own.")
                FeatureRow("display.2", "Per-display rotation & playlists", "Keep every screen fresh, automatically.")
            }
            .frame(maxWidth: 420)
            Text("You can explore everything free first — the paywall only appears when you try a Premium wallpaper or feature.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }
}

// MARK: - Small pieces

private struct FeatureRow: View {
    let icon: String, title: String, detail: String
    init(_ icon: String, _ title: String, _ detail: String) {
        self.icon = icon; self.title = title; self.detail = detail
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The app's prism mark as a filled rounded badge — the same glyph used in the menu bar, sized up
/// for the onboarding hero. Falls back gracefully if the SF Symbol is unavailable.
private struct PrismGlyph: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .shadow(color: .accentColor.opacity(0.35), radius: 8, y: 3)
    }
}

// MARK: - Window controller

/// Hosts `OnboardingView` in a small titled window. Closing it any way marks onboarding complete via
/// `Preferences`, so the walkthrough never reappears unasked. `openMain` is invoked only when the
/// user finishes with "Get Started".
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var openMain: (() -> Void)?

    func show(model: AppModel, openMain: @escaping () -> Void) {
        self.openMain = openMain
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(model: model) { [weak self] wantsMain in
            self?.finish(openMain: wantsMain)
        })
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 560, height: 560))
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    /// Dismiss from a button: remember whether to open the main window, then close (which marks done).
    private func finish(openMain wantsMain: Bool) {
        pendingOpenMain = wantsMain
        window?.close()
    }
    private var pendingOpenMain = false

    // Any close path (button or red traffic light) lands here — mark complete exactly once.
    func windowWillClose(_ notification: Notification) {
        Preferences.shared.hasCompletedOnboarding = true
        window = nil
        if pendingOpenMain { openMain?() }
        pendingOpenMain = false
    }
}
