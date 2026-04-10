import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh Interval: \(String(format: "%.1f", prefs.refreshInterval))s")
                    .font(.subheadline)
                Slider(value: $prefs.refreshInterval, in: 0.5...10.0, step: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("CPU Alert Threshold: \(Int(prefs.cpuAlertThreshold * 100))%")
                    .font(.subheadline)
                Slider(value: $prefs.cpuAlertThreshold, in: 0.01...0.5, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("RAM Alert Threshold: \(Int(prefs.ramAlertThresholdMB)) MB")
                    .font(.subheadline)
                Slider(value: $prefs.ramAlertThresholdMB, in: 50...2000, step: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Alert Sensitivity")
                    .font(.subheadline)
                Picker("", selection: $prefs.sensitivity) {
                    ForEach(Sensitivity.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(sensitivityHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Ignored Bundle IDs")
                    .font(.subheadline)
                TextField("com.example.App, …", text: $prefs.ignoredBundleIDsRaw)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Text("Comma-separated. Matching apps are excluded from scanning.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var sensitivityHint: String {
        switch prefs.sensitivity {
        case .conservative: return "Thresholds doubled — fewer alerts."
        case .default_:     return "Default thresholds."
        case .aggressive:   return "Thresholds halved — more alerts."
        }
    }
}
