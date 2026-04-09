import AppKit
import SwiftUI

/// An immutable snapshot of a single menu-bar process captured during one
/// sampling tick by `ProcessMonitor`.
///
/// `MenuBarProcess` is a value type — each `sample()` call produces a fresh
/// array of structs rather than mutating existing objects. Views bind to the
/// published array on `ProcessMonitor` and re-render when the reference
/// changes.
struct MenuBarProcess: Identifiable {

    /// Stable identity using the UNIX process ID.
    ///
    /// PIDs are reused by the OS after a process exits, but `ProcessMonitor`
    /// prunes stale entries each tick, so two consecutive samples with the
    /// same PID represent the same live process.
    var id: pid_t { pid }

    /// UNIX process identifier.
    let pid: pid_t

    /// Localized display name from `NSRunningApplication.localizedName`.
    /// Falls back to `"Unknown"` if the system returns `nil`.
    let name: String

    /// Bundle identifier (e.g. `"com.example.App"`), or `nil` for processes
    /// that were not launched from a bundle.
    let bundleIdentifier: String?

    /// App icon returned by `NSRunningApplication.icon`, suitable for display
    /// in list rows. May be `nil` if the OS cannot locate the app bundle.
    let icon: NSImage?

    /// CPU utilisation as a fraction of **one logical core** during the last
    /// sampling interval, in the range `[0, 1]`.
    ///
    /// Computed as `Δcpu_ns / Δwall_ns` and capped at `1.0`. The cap is
    /// necessary because a process running hot threads across multiple cores
    /// can accumulate more CPU nanoseconds than wall-clock nanoseconds elapsed.
    let cpuFraction: Double

    /// Rolling buffer of the last 20 `cpuFraction` samples in chronological
    /// order (oldest first). Populated and maintained by `ProcessMonitor`.
    /// Used by `SparklineView` to render a CPU trend chart.
    let cpuHistory: [Double]

    /// Resident set size in bytes, as reported by `proc_taskinfo.pti_resident_size`.
    /// This is the amount of physical RAM currently mapped and resident for
    /// the process (not virtual memory).
    let residentMemoryBytes: UInt64

    /// System thermal state at the moment this snapshot was captured.
    ///
    /// All processes in a single sample share the same thermal state value
    /// because it is a system-wide property queried once per `sample()` call.
    /// Used by `ThermalHeaderView` to colour the heatmap header.
    let thermalState: ProcessInfo.ThermalState

    /// Date the process was launched, from `NSRunningApplication.launchDate`.
    /// `nil` when the OS cannot determine the launch time.
    let launchDate: Date?

    // MARK: - Computed display helpers

    /// Human-readable CPU percentage string, e.g. `"12.3%"`.
    var cpuString: String {
        String(format: "%.1f%%", cpuFraction * 100)
    }

    /// Colour used to tint the CPU label, escalating with load:
    /// - < 5 %  → `.primary` (no emphasis)
    /// - 5–25 % → `.orange`
    /// - ≥ 25 % → `.red`
    var cpuColor: Color {
        switch cpuFraction {
        case ..<0.05: return .primary
        case ..<0.25: return .orange
        default:      return .red
        }
    }

    /// Human-readable memory string that auto-scales from MB to GB.
    /// Values below 1 000 MB are shown as `"NNN MB"`; at or above that
    /// threshold they are shown as `"N.NN GB"`.
    var memoryString: String {
        let mb = Double(residentMemoryBytes) / 1_048_576
        if mb < 1_000 {
            return String(format: "%.0f MB", mb)
        } else {
            return String(format: "%.2f GB", mb / 1_024)
        }
    }
}
