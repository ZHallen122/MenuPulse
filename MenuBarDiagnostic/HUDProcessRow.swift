import SwiftUI
import AppKit

struct HUDProcessRow: View {
    let process: MenuBarProcess
    var cpuAlertThreshold: Double = 0.05
    var ramAlertThresholdMB: Double = 200.0

    @State private var pulse = false
    @State private var showDetail = false

    private var isHogging: Bool {
        process.cpuFraction > cpuAlertThreshold ||
        process.memoryFootprintBytes > UInt64(ramAlertThresholdMB * 1024 * 1024)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Top: icon + name + chevron + CPU%
            HStack(spacing: 8) {
                iconView
                Text(process.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isHogging ? .white : .primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(process.cpuString)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(isHogging ? .white : process.cpuColor)
            }

            // Sparkline: last 20 CPU samples
            SparklineView(values: process.cpuHistory)
                .frame(height: 22)
                .animation(.easeInOut(duration: 0.35), value: process.cpuHistory)

            // RAM bar
            RAMBarView(bytes: process.memoryFootprintBytes, maxBytes: 500 * 1024 * 1024)
                .frame(height: 4)

            // RAM label
            Text(process.memoryString)
                .font(.caption2.monospacedDigit())
                .foregroundColor(isHogging ? .white.opacity(0.85) : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .shadow(
            color: .red.opacity(isHogging ? (pulse ? 0.75 : 0.15) : 0),
            radius: isHogging ? (pulse ? 14 : 3) : 0
        )
        .onAppear {
            if isHogging {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .onTapGesture {
            showDetail = true
        }
        .sheet(isPresented: $showDetail) {
            ProcessDetailSheet(process: process)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = process.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.fill")
                .frame(width: 20, height: 20)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHogging {
            Color.red.opacity(0.30)
        } else {
            Color.clear
        }
    }
}
