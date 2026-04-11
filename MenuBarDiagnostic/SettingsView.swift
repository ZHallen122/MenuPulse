import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    var anomalyDetector: AnomalyDetector

    var body: some View {
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
                TextField("Ignore Apps", text: $prefs.ignoredBundleIDsRaw, prompt: Text("com.example.App, …"))
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
                Text("Starts Bouncer automatically when you log in.")
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Show Memory Pressure", isOn: $prefs.showMemoryPressureInMenuBar)
            } footer: {
                Text("Displays RAM usage % next to the menu bar icon.")
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Testing Mode", isOn: $prefs.testingMode)
                if prefs.testingMode {
                    Button("Fire Test Alert Now") {
                        anomalyDetector.fireTestAlert()
                    }
                }
            } header: {
                Text("Developer")
            } footer: {
                Text(prefs.testingMode
                     ? "Learning period and memory pressure guard are bypassed. Time windows collapsed to seconds. \"Fire Test Alert Now\" sends a synthetic notification immediately."
                     : "Enable to exercise alert detection without the 3-day learning period or real memory pressure.")
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420, height: prefs.testingMode ? 430 : 400)
    }
}
