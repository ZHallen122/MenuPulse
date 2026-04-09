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

    private var headerBar: some View {
        HStack {
            Text("Menu Bar Processes")
                .font(.headline)
            Spacer()
            Label(thermalLabel, systemImage: thermalIcon)
                .font(.caption)
                .foregroundColor(thermalColor)
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

    // MARK: - Thermal helpers

    private var currentThermalState: ProcessInfo.ThermalState {
        monitor.processes.first?.thermalState ?? ProcessInfo.processInfo.thermalState
    }

    private var thermalLabel: String {
        switch currentThermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalIcon: String {
        switch currentThermalState {
        case .nominal:  return "thermometer.low"
        case .fair:     return "thermometer.medium"
        case .serious:  return "thermometer.high"
        case .critical: return "thermometer.sun.fill"
        @unknown default: return "thermometer"
        }
    }

    private var thermalColor: Color {
        switch currentThermalState {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
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
            Text(cpuString)
                .font(.caption.monospacedDigit())
                .foregroundColor(cpuColor)
            Text(memoryString)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var cpuString: String {
        String(format: "%.1f%%", process.cpuFraction * 100)
    }

    private var cpuColor: Color {
        switch process.cpuFraction {
        case ..<0.05: return .primary
        case ..<0.25: return .orange
        default:      return .red
        }
    }

    private var memoryString: String {
        let mb = Double(process.residentMemoryBytes) / 1_048_576
        if mb < 1_000 {
            return String(format: "%.0f MB", mb)
        } else {
            return String(format: "%.2f GB", mb / 1_024)
        }
    }
}

#Preview {
    let prefs = PreferencesManager()
    return StatusMenuView(monitor: ProcessMonitor(prefs: prefs), prefs: prefs)
}
