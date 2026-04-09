import AppKit

struct MenuBarProcess: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let cpuFraction: Double
    let residentMemoryBytes: UInt64
    let thermalState: ProcessInfo.ThermalState
}
