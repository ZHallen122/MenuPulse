import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    var anomalyDetector: AnomalyDetector
    var onCheckForUpdates: (() -> Void)? = nil

    var body: some View {
        TabView {
            GeneralSettingsView(prefs: prefs, onCheckForUpdates: onCheckForUpdates)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            #if DEBUG
            DeveloperSettingsView(prefs: prefs, anomalyDetector: anomalyDetector)
                .tabItem {
                    Label("Developer", systemImage: "hammer")
                }
            #endif
        }
        .frame(width: 550)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    var onCheckForUpdates: (() -> Void)? = nil

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
                Text("Enter app bundle IDs separated by commas (e.g. com.example.App). Bouncer will skip these apps entirely.")
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: $prefs.launchAtLogin)
                Toggle("Automatically Check for Updates", isOn: $prefs.automaticUpdateChecks)
                Button("Check for Updates Now") {
                    onCheckForUpdates?()
                }
            } header: {
                Text("System")
            } footer: {
                Text("Bouncer can start automatically at login, stay up to date in the background, or let you check for updates on demand.")
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Show Memory Pressure", isOn: $prefs.showMemoryPressureInMenuBar)
            } header: {
                Text("Display")
            } footer: {
                Text("Shows how much memory your Mac is using, right in the menu bar.")
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

struct DeveloperSettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    var anomalyDetector: AnomalyDetector

    // Ticks every second so the learning-period countdown stays live.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var localTestColor: String = "normal"

    var body: some View {
        Form {
            Section {
                Toggle("Testing Mode", isOn: $prefs.testingMode)
                if prefs.testingMode {
                    Button("Fire Test Alert Now") {
                        anomalyDetector.fireTestAlert()
                    }
                    Picker("Test Icon Color", selection: $localTestColor) {
                        Text("Default").tag("normal")
                        Text("Orange").tag("orange")
                        Text("Red").tag("red")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: localTestColor) { newColor in
                        NotificationCenter.default.post(name: .testColorOverride, object: newColor)
                    }
                }
                Button("Reset Learning Period") {
                    prefs.resetLearningPeriod()
                    now = Date()
                }
                learningPeriodStatus
            } header: {
                Text("Developer")
            } footer: {
                Text(developerFooter)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .onReceive(timer) { tick in
            now = tick
        }
    }

    @ViewBuilder
    private var learningPeriodStatus: some View {
        let inPeriod = now.timeIntervalSince(prefs.firstLaunchDate) < prefs.learningPeriodDuration
        if inPeriod {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                Text("Learning — \(prefs.learningPeriodRemainingLabel(now: now))")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Learning period complete — alerts active")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private var developerFooter: String {
        if prefs.testingMode {
            return "Testing Mode is active: thresholds and time windows are compressed so you can verify the full alert flow quickly. Reset the learning period, then fire a test alert to confirm everything works."
        }
        return "Reset the learning period to restart the 3-day baseline window. Alerts are suppressed while Bouncer is still learning normal behavior."
    }
}
