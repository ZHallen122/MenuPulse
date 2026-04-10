import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesManager

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Sensitivity", selection: $prefs.sensitivity) {
                        ForEach(Sensitivity.allCases, id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Controls how aggressively Bouncer flags memory anomalies. Higher sensitivity may produce more alerts.")
                        .foregroundColor(.secondary)
                }

                Section {
                    TextField("com.example.App, …", text: $prefs.ignoredBundleIDsRaw)
                        .font(.caption.monospaced())
                } header: {
                    Text("Exclusions")
                } footer: {
                    Text("Comma-separated bundle IDs. Matching apps are excluded from anomaly scanning.")
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Launch at Login", isOn: $prefs.launchAtLogin)
                } header: {
                    Text("System")
                } footer: {
                    Text("Automatically start Bouncer when you log in.")
                        .foregroundColor(.secondary)
                }
            }
            .tabItem {
                Label("General", systemImage: "gear")
            }
        }
        .frame(minWidth: 400, minHeight: 320)
    }
}
