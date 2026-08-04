import AppKit
import SwiftUI

/// App-level preferences UI (distinct from per-wallpaper "Wallpaper Settings"). Binds straight to
/// `Preferences.shared`, whose setters persist and fire `onChange`.
struct PreferencesView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                Toggle("Check for updates automatically", isOn: $prefs.checkForUpdatesAutomatically)
            }
            Section("Power") {
                Picker("On battery", selection: $prefs.batteryBehavior) {
                    ForEach(BatteryBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Wallpapers always pause when covered, on lock, or when the display sleeps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rotation") {
                Toggle("Rotate through all wallpapers", isOn: $prefs.rotationEnabled)
                Stepper("Every \(prefs.rotationMinutes) min", value: $prefs.rotationMinutes, in: 1...240)
                    .disabled(!prefs.rotationEnabled)
            }
            Section("Language") {
                Picker(LocalizedStringKey("settings.language"), selection: $prefs.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 300)
    }
}
