import SwiftUI

struct ThermalHeaderView: View {
    let thermalState: ProcessInfo.ThermalState
    let systemCPUFraction: Double
    let systemRAMUsedBytes: UInt64
    let systemRAMTotalBytes: UInt64

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [thermalState.thermalColor.opacity(0.55), thermalState.thermalColor.opacity(0.15)]),
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bouncer")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Label(thermalState.thermalLabel, systemImage: thermalState.thermalIcon)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    Spacer()
                    // Thermal heatmap block
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(thermalState.thermalColor)
                            .shadow(color: thermalState.thermalColor.opacity(0.6), radius: 8)
                        Text(thermalState.thermalLabel)
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                    }
                    .frame(width: 62, height: 28)
                }
                SystemSummaryRow(
                    cpuFraction: systemCPUFraction,
                    ramUsedBytes: systemRAMUsedBytes,
                    ramTotalBytes: systemRAMTotalBytes
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - System Summary Row

struct SystemSummaryRow: View {
    let cpuFraction: Double
    let ramUsedBytes: UInt64
    let ramTotalBytes: UInt64

    var body: some View {
        HStack {
            Text(String(format: "CPU: %.1f%%", cpuFraction * 100))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            Text(ramString)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private var ramString: String {
        let usedGB = Double(ramUsedBytes) / 1_073_741_824
        let totalGB = Double(ramTotalBytes) / 1_073_741_824
        if totalGB > 0 {
            return String(format: "RAM: %.1f / %.0f GB", usedGB, totalGB)
        }
        return String(format: "RAM: %.1f GB", usedGB)
    }
}
