import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

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
            }

            Toggle("Launch at login", isOn: $prefs.launchAtLogin)

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
}
