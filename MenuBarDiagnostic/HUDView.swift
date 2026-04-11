import SwiftUI
import AppKit

// MARK: - HUDView (root)

struct HUDView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var prefs: PreferencesManager
    @State private var gradientRotation: Double = 0
    /// Tracks which bundleIDs' update banners have been dismissed for this session.
    @State private var dismissedUpdateIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ThermalHeaderView(
                thermalState: currentThermalState,
                systemCPUFraction: monitor.systemCPUFraction,
                systemRAMUsedBytes: monitor.systemRAMUsedBytes,
                systemRAMTotalBytes: monitor.systemRAMTotalBytes
            )
            Divider().opacity(0.4)
            processListView
        }
        .frame(width: 360, height: 500)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.blue, .cyan, .purple, .blue]),
                        center: .center,
                        angle: .degrees(gradientRotation)
                    ),
                    lineWidth: 2
                )
        )
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                gradientRotation = 360
            }
        }
    }

    private var currentThermalState: ProcessInfo.ThermalState {
        monitor.processes.first?.thermalState ?? ProcessInfo.processInfo.thermalState
    }

    @ViewBuilder
    private var processListView: some View {
        if monitor.processes.isEmpty {
            Text("No menu bar processes found")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    updateBanner
                    ForEach(monitor.processes) { process in
                        HUDProcessRow(
                            process: process,
                            cpuAlertThreshold: prefs.cpuAlertThreshold,
                            ramAlertThresholdMB: prefs.ramAlertThresholdMB,
                            isLearning: monitor.learningBundleIDs.contains(process.bundleIdentifier ?? "")
                        )
                        .id(process.pid)
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    /// Banner shown when one or more apps were recently updated and are relearning.
    @ViewBuilder
    private var updateBanner: some View {
        let visibleUpdates = monitor.recentlyUpdatedApps.filter { !dismissedUpdateIDs.contains($0.key) }
        if !visibleUpdates.isEmpty {
            let names = visibleUpdates.values.sorted().joined(separator: ", ")
            HStack(spacing: 8) {
                Text("\(names) was updated — relearning memory profile.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    for key in visibleUpdates.keys { dismissedUpdateIDs.insert(key) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.12))
            Divider().opacity(0.25)
        }
    }
}
