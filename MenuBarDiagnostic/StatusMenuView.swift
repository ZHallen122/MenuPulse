import SwiftUI
import AppKit

struct StatusMenuView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var prefs: PreferencesManager
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            learningBanner
            processListOrEmpty
            Divider()
            footerBar
        }
        .frame(width: 320)
        .sheet(isPresented: $showSettings) {
            SettingsView(prefs: prefs)
        }
    }

    // MARK: - Sub-views

    private var learningBanner: some View {
        let defaults = UserDefaults.standard
        let firstLaunch: Date = {
            if let d = defaults.object(forKey: "firstLaunchDate") as? Date { return d }
            let now = Date()
            defaults.set(now, forKey: "firstLaunchDate")
            return now
        }()
        let elapsed = Date().timeIntervalSince(firstLaunch)
        let learningPeriod: TimeInterval = 3 * 86400
        guard elapsed < learningPeriod else { return AnyView(EmptyView()) }
        let daysRemaining = max(1, Int(ceil((learningPeriod - elapsed) / 86400)))
        return AnyView(
            Text("Bouncer is learning… smart alerts start in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.85))
        )
    }

    private var headerBar: some View {
        HStack {
            Text("Menu Bar Processes")
                .font(.headline)
            Spacer()
            Label(currentThermalState.thermalLabel, systemImage: currentThermalState.thermalIcon)
                .font(.caption)
                .foregroundColor(currentThermalState.thermalColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var processListOrEmpty: some View {
        Group {
            if monitor.processes.isEmpty {
                Text("No menu bar processes found")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(monitor.processes) { process in
                            ProcessRow(process: process)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button("About") { NSApp.orderFrontStandardAboutPanel(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
            Spacer()
            Button("Settings") { showSettings = true }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var currentThermalState: ProcessInfo.ThermalState {
        monitor.processes.first?.thermalState ?? ProcessInfo.processInfo.thermalState
    }
}

// MARK: - ProcessRow

private struct ProcessRow: View {
    let process: MenuBarProcess

    var body: some View {
        HStack(spacing: 8) {
            iconView
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            metricsView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = process.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.fill")
                .frame(width: 18, height: 18)
                .foregroundColor(.secondary)
        }
    }

    private var metricsView: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(process.cpuString)
                .font(.caption.monospacedDigit())
                .foregroundColor(process.cpuColor)
            Text(process.memoryString)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    let prefs = PreferencesManager()
    return StatusMenuView(monitor: ProcessMonitor(prefs: prefs), prefs: prefs)
}
