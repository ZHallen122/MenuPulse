import SwiftUI
import AppKit

struct StatusMenuView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var prefs: PreferencesManager
    @ObservedObject var anomalyDetector: AnomalyDetector
    @ObservedObject var swapMonitor: SwapMonitor
    var onSettingsTap: () -> Void
    var onClosePopover: () -> Void = {}
    @State private var expandedPID: pid_t? = nil
    @State private var hoveredFooterButton: String? = nil

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
        .onDisappear { hoveredFooterButton = nil }
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        let appCount = displayProcesses.count
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
            if swapMonitor.swapState == .swapCritical {
                Text("Swap: critical growth (1 GB+ / 5 min)")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if swapMonitor.swapState == .swapSignificant {
                Text("Swap: significant growth (500 MB+ / 5 min)")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if swapMonitor.swapState == .swapMinor {
                Text("Swap: growing (100 MB+ / 5 min)")
                    .font(.caption)
                    .foregroundColor(.yellow)
            } else if swapMonitor.swapState == .compressedGrowing {
                Text("Compressed memory growing (300 MB+ / 5 min)")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Learning Banner

    private var learningBanner: some View {
        let elapsed = Date().timeIntervalSince(prefs.firstLaunchDate)
        let duration = prefs.learningPeriodDuration
        guard elapsed < duration else { return AnyView(EmptyView()) }
        let remaining = duration - elapsed
        let label: String
        if prefs.testingMode {
            label = "Bouncer is learning… smart alerts start in \(max(1, Int(remaining))) s"
        } else {
            let daysRemaining = max(1, Int(ceil(remaining / 86400)))
            label = "Bouncer is learning… smart alerts start in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")"
        }
        return AnyView(
            Text(label)
                .font(.caption)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
        )
    }

    // MARK: - Process Sections

    private var displayProcesses: [MenuBarProcess] {
        let ignored = Set(prefs.ignoredBundleIDs)
        return monitor.processes
            .filter { process in
                guard let bid = process.bundleIdentifier else { return true }
                return !ignored.contains(bid)
            }
            .sorted { p1, p2 in
                let a1 = anomalyDetector.anomalousBundleIDs.contains(p1.bundleIdentifier ?? "")
                let a2 = anomalyDetector.anomalousBundleIDs.contains(p2.bundleIdentifier ?? "")

                if a1 && !a2 { return true }
                if !a1 && a2 { return false }

                return p1.memoryFootprintBytes > p2.memoryFootprintBytes
            }
    }

    @ViewBuilder
    private var processListOrEmpty: some View {
        if monitor.processes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No apps running")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Apps appear here as they use memory")
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displayProcesses) { process in
                        let isAnomalous = anomalyDetector.anomalousBundleIDs.contains(process.bundleIdentifier ?? "")
                        ProcessRowView(
                            process: process,
                            isAnomalous: isAnomalous,
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
            .foregroundColor(hoveredFooterButton == "about" ? .primary : .secondary)
            .font(.caption)
            .onHover { hoveredFooterButton = $0 ? "about" : nil }
            Spacer()
            if #available(macOS 14.0, *) {
                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(.plain)
                .foregroundColor(hoveredFooterButton == "settings" ? .primary : .secondary)
                .font(.caption)
                .onHover { hoveredFooterButton = $0 ? "settings" : nil }
                .simultaneousGesture(TapGesture().onEnded {
                    onClosePopover()
                    NSApp.activate(ignoringOtherApps: true)
                })
            } else {
                Button("Settings") {
                    onClosePopover()
                    onSettingsTap()
                }
                .buttonStyle(.plain)
                .foregroundColor(hoveredFooterButton == "settings" ? .primary : .secondary)
                .font(.caption)
                .onHover { hoveredFooterButton = $0 ? "settings" : nil }
            }
            Spacer()
            Button("Quit") {
                onClosePopover()
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(hoveredFooterButton == "quit" ? .primary : .secondary)
            .font(.caption)
            .onHover { hoveredFooterButton = $0 ? "quit" : nil }
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
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { onTap() } }
            if isExpanded {
                detailCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
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
                    Text(String(format: "Normal: %.0f MB avg", b.p90MB))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Text("Still learning baseline…")
                        .font(.caption)
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
                .help("Force-quit this app")
                Button("Restart App") {
                    restartApp()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .help("Quit and relaunch this app")
                if isAnomalous {
                    Button("Add to Ignore List") {
                        if let bid = process.bundleIdentifier,
                           !prefs.ignoredBundleIDs.contains(bid) {
                            prefs.ignoredBundleIDs.append(bid)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop alerting about this app")
                }
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
    let swapMonitor = SwapMonitor()
    return StatusMenuView(monitor: monitor, prefs: prefs, anomalyDetector: detector, swapMonitor: swapMonitor, onSettingsTap: {})
}
