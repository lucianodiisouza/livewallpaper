import AppKit
import SwiftUI

/// Holds the live config values for the current wallpaper and notifies on change. The SwiftUI form
/// below is generated entirely from `schema`, so any wallpaper's parameters get a UI for free.
@MainActor
final class ConfigStore: ObservableObject {
    let schema: [ConfigParameter]
    @Published var values: [String: ConfigValue]
    var onChange: (([String: ConfigValue]) -> Void)?

    init(schema: [ConfigParameter], values: [String: ConfigValue]) {
        self.schema = schema
        self.values = values
    }

    fileprivate func set(_ key: String, _ value: ConfigValue) {
        values[key] = value
        onChange?(values)
    }
}

/// Auto-generated settings form: one control per `ConfigParameter`, by kind.
struct ConfigForm: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            ForEach(store.schema) { param in
                row(for: param)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 120)
    }

    @ViewBuilder
    private func row(for param: ConfigParameter) -> some View {
        switch param.kind {
        case let .float(min, max, _):
            let binding = Binding<Double>(
                get: { store.values[param.key]?.asDouble ?? min },
                set: { store.set(param.key, .float($0)) })
            VStack(alignment: .leading) {
                Text("\(param.label): \(binding.wrappedValue, specifier: "%.2f")")
                Slider(value: binding, in: min...max)
            }
        case .bool:
            let binding = Binding<Bool>(
                get: { store.values[param.key]?.asBool ?? false },
                set: { store.set(param.key, .bool($0)) })
            Toggle(param.label, isOn: binding)
        case .color:
            let binding = Binding<Color>(
                get: { Self.color(fromHex: store.values[param.key]?.asHex ?? "#FFFFFF") },
                set: { store.set(param.key, .color(Self.hex(from: $0))) })
            ColorPicker(param.label, selection: binding, supportsOpacity: false)
        }
    }

    private static func color(fromHex hex: String) -> Color {
        guard let (r, g, b) = MetalRenderer.rgb(fromHex: hex) else { return .white }
        return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b))
    }

    private static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Presents the settings form in a normal window (the app is otherwise a menu-bar accessory).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(store: ConfigStore, title: String) {
        window?.close()
        let hosting = NSHostingController(rootView: ConfigForm(store: store))
        let w = NSWindow(contentViewController: hosting)
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 340, height: 180))
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
