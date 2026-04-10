import SwiftUI
import AppKit

struct StatusMenuView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var prefs: PreferencesManager
    @ObservedObject var anomalyDetector: AnomalyDetector
    var onSettingsTap: () -> Void
    var onClosePopover: () -> Void = {}
    @State private var expandedPID: pid_t? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryHeader
            Divider()
            learningBanner
            processListOrEmpty
            Divider()
            footerBar
        }
        .frame(width: 300)
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        let appCount = monitor.processes.count
        let anomalyCount = anomalyDetector.anomalousBundleIDs.count
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(appCount) app\(appCount == 1 ? "" : "s") running")
                .font(.headline)
            if prefs.isInLearningPeriod {
                Text("Learning your apps…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("\(anomalyCount) behaving abnormally")
                    .font(.caption)
                    .foregroundColor(anomalyCount > 0 ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Learning Banner

    private var learningBanner: some View {
        let elapsed = Date().timeIntervalSince(prefs.firstLaunchDate)
        let learningPeriod: TimeInterval = 3 * 86400
        guard elapsed < learningPeriod else { return AnyView(EmptyView()) }
        let daysRemaining = max(1, Int(ceil((learningPeriod - elapsed) / 86400)))
        return AnyView(
            Text("Bouncer is learning… smart alerts start in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.85))
        )
    }

    // MARK: - Process Sections

    private var anomalousProcesses: [MenuBarProcess] {
        monitor.processes
            .filter { p in
                guard let bid = p.bundleIdentifier else { return false }
                return anomalyDetector.anomalousBundleIDs.contains(bid)
            }
            .sorted { $0.memoryFootprintBytes > $1.memoryFootprintBytes }
    }

    private var normalProcesses: [MenuBarProcess] {
        monitor.processes
            .filter { p in
                guard let bid = p.bundleIdentifier else { return true }
                return !anomalyDetector.anomalousBundleIDs.contains(bid)
            }
            .sorted { $0.memoryFootprintBytes > $1.memoryFootprintBytes }
    }

    @ViewBuilder
    private var processListOrEmpty: some View {
        if monitor.processes.isEmpty {
            Text("No menu bar processes found")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !anomalousProcesses.isEmpty {
                        ForEach(anomalousProcesses) { process in
                            ProcessRowView(
                                process: process,
                                isAnomalous: true,
                                isExpanded: expandedPID == process.pid,
                                monitor: monitor,
                                prefs: prefs,
                                onTap: {
                                    expandedPID = expandedPID == process.pid ? nil : process.pid
                                }
                            )
                            Divider()
                        }
                    }
                    ForEach(normalProcesses) { process in
                        ProcessRowView(
                            process: process,
                            isAnomalous: false,
                            isExpanded: expandedPID == process.pid,
                            monitor: monitor,
                            prefs: prefs,
                            onTap: {
                                expandedPID = expandedPID == process.pid ? nil : process.pid
                            }
                        )
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button("About") {
                onClosePopover()
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
            Spacer()
            Button("Settings") {
                onClosePopover()
                onSettingsTap()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
            Spacer()
            Button("Quit") {
                onClosePopover()
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - ProcessRowView

private struct ProcessRowView: View {
    let process: MenuBarProcess
    let isAnomalous: Bool
    let isExpanded: Bool
    let monitor: ProcessMonitor
    let prefs: PreferencesManager
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
            if isExpanded {
                detailCard
            }
        }
        .background(isAnomalous ? Color.orange.opacity(0.08) : Color.clear)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            iconView
            Text(process.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isAnomalous ? .primary : .secondary)
            Spacer()
            Text(process.memoryString)
                .font(.caption.monospacedDigit())
                .foregroundColor(isAnomalous ? .orange : .secondary)
            SparklineView(values: process.memoryHistory, color: isAnomalous ? .orange : .blue)
                .frame(width: 40, height: 16)
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

    private var detailCard: some View {
        let bundleID = process.bundleIdentifier ?? ""
        let baseline = bundleID.isEmpty ? nil : monitor.dataStore.baseline(for: bundleID)
        let currentMB = Double(process.memoryFootprintBytes) / 1_048_576.0
        let since = Date().addingTimeInterval(-30 * 60)
        let samples = bundleID.isEmpty ? [] : monitor.dataStore.recentSamples(for: bundleID, since: since)
        let trend = trendLabel(samples: samples)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "Current: %.0f MB", currentMB))
                    .font(.caption.monospacedDigit())
                Spacer()
                if let b = baseline {
                    Text(String(format: "Baseline p90: %.0f MB", b.p90MB))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Text("Trend: \(trend)")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("Quit App") {
                    quitApp()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                Button("Restart App") {
                    restartApp()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                Button("Add to Ignore List") {
                    if let bid = process.bundleIdentifier,
                       !prefs.ignoredBundleIDs.contains(bid) {
                        prefs.ignoredBundleIDs.append(bid)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Helpers

    private func trendLabel(samples: [(memoryMB: Double, timestamp: Date)]) -> String {
        guard samples.count >= 2 else { return "Stable" }
        let slope = linearRegressionSlope(samples)
        let threshold = 0.001 // MB per second
        if slope > threshold { return "Increasing" }
        if slope < -threshold { return "Decreasing" }
        return "Stable"
    }

    private func linearRegressionSlope(_ samples: [(memoryMB: Double, timestamp: Date)]) -> Double {
        guard let first = samples.first else { return 0 }
        let n = Double(samples.count)
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumX2: Double = 0
        for s in samples {
            let x = s.timestamp.timeIntervalSince(first.timestamp)
            let y = s.memoryMB
            sumX += x; sumY += y; sumXY += x * y; sumX2 += x * x
        }
        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return 0 }
        return (n * sumXY - sumX * sumY) / denominator
    }

    private func quitApp() {
        guard let bundleID = process.bundleIdentifier else { return }
        let workspace = NSWorkspace.shared
        guard let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }
        app.terminate()
    }

    private func restartApp() {
        guard let bundleID = process.bundleIdentifier else { return }
        let workspace = NSWorkspace.shared
        guard let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }
        let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID)
        app.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard let url = appURL else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

#Preview {
    let prefs = PreferencesManager()
    let monitor = ProcessMonitor(prefs: prefs)
    let detector = AnomalyDetector(dataStore: monitor.dataStore, prefs: prefs)
    return StatusMenuView(monitor: monitor, prefs: prefs, anomalyDetector: detector, onSettingsTap: {})
}
