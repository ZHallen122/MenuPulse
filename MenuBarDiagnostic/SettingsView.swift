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
            
            BlockListSettingsView(prefs: prefs)
                .tabItem {
                    Label("Ignored Apps", systemImage: "nosign")
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
                Toggle("Show RAM Usage in Menu Bar", isOn: $prefs.showMemoryPressureInMenuBar)
            } header: {
                Text("Display")
            } footer: {
                Text("Shows your current RAM usage percentage next to the Bouncer icon.")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
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
        .formStyle(.grouped)
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

struct BlockListSettingsView: View {
    @ObservedObject var prefs: PreferencesManager
    @State private var selection: Set<String> = []
    @State private var showingAddPopover = false
    @State private var newBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apps in the ignored list will not be monitored or alerted on by Bouncer.")
                .foregroundColor(.secondary)

            VStack(spacing: -1) {
                List(selection: $selection) {
                    ForEach(prefs.ignoredBundleIDs, id: \.self) { bundleID in
                        Text(bundleID)
                            .tag(bundleID)
                    }
                }
                .onChange(of: prefs.ignoredBundleIDs) { _ in
                    selection = selection.filter { prefs.ignoredBundleIDs.contains($0) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    Button(action: {
                        showingAddPopover = true
                    }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingAddPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add App to Block List")
                                .font(.headline)
                            
                            TextField("Bundle ID (e.g. com.example.App)", text: $newBundleID)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                            
                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    showingAddPopover = false
                                    newBundleID = ""
                                }
                                .keyboardShortcut(.cancelAction)
                                
                                Button("Add") {
                                    addBundleID(newBundleID)
                                    showingAddPopover = false
                                    newBundleID = ""
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding()
                    }

                    Button(action: {
                        removeSelected()
                    }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(selection.isEmpty)

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(
                    .rect(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 6,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 0
                    )
                )
                .overlay(
                    CustomCornerBorder()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
            .frame(maxHeight: 300)
        }
        .padding()
    }
    
    private func addBundleID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = prefs.ignoredBundleIDs
        if !current.contains(trimmed) {
            current.append(trimmed)
            prefs.ignoredBundleIDs = current
        }
    }
    
    private func removeSelected() {
        var current = prefs.ignoredBundleIDs
        current.removeAll { selection.contains($0) }
        prefs.ignoredBundleIDs = current
        selection.removeAll()
    }
}

private struct CustomCornerBorder: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 6))
        path.addArc(
            center: CGPoint(x: rect.minX + 6, y: rect.maxY - 6),
            radius: 6,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.maxX - 6, y: rect.maxY - 6),
            radius: 6,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
