import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    var anomalyDetector: AnomalyDetector

    // Ticks every second so the learning-period countdown stays live.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var localTestColor: String = "normal"

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
        .frame(width: 420, height: prefs.testingMode ? 520 : 450)
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
            return "Testing Mode ON: learning period is 30 s, memory pressure guard bypassed, time windows collapsed to seconds. Reset → watch countdown → alerts fire automatically."
        }
        return "Reset Learning Period restarts the 3-day window (Testing Mode OFF) to verify alerts are suppressed during learning."
    }
}
