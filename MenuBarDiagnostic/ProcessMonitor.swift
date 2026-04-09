import AppKit
import Darwin

class ProcessMonitor: ObservableObject {
    @Published var processes: [MenuBarProcess] = []

    private var timer: Timer?
    // pid -> (accumulated CPU nanoseconds, wall-clock nanoseconds)
    private var previousSamples: [pid_t: (cpuNanos: UInt64, wallNanos: UInt64)] = [:]
    // pid -> rolling CPU history (last 20 samples)
    private var cpuHistories: [pid_t: [Double]] = [:]

    func startMonitoring() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let thermalState = ProcessInfo.processInfo.thermalState
        let wallNow = DispatchTime.now().uptimeNanoseconds

        let accessoryApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .accessory
        }

        var newProcesses: [MenuBarProcess] = []

        for app in accessoryApps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            var info = proc_taskinfo()
            let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize)
            guard ret == infoSize else { continue }

            let cpuNow = info.pti_total_user + info.pti_total_system

            var cpuFraction: Double = 0.0
            if let prev = previousSamples[pid] {
                let cpuDelta = cpuNow >= prev.cpuNanos ? cpuNow - prev.cpuNanos : 0
                let wallDelta = wallNow > prev.wallNanos ? wallNow - prev.wallNanos : 1
                cpuFraction = min(Double(cpuDelta) / Double(wallDelta), 1.0)
            }

            previousSamples[pid] = (cpuNanos: cpuNow, wallNanos: wallNow)

            // Maintain rolling CPU history (max 20 samples)
            var history = cpuHistories[pid] ?? []
            history.append(cpuFraction)
            if history.count > 20 { history.removeFirst(history.count - 20) }
            cpuHistories[pid] = history

            newProcesses.append(MenuBarProcess(
                pid: pid,
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                cpuFraction: cpuFraction,
                cpuHistory: history,
                residentMemoryBytes: info.pti_resident_size,
                thermalState: thermalState
            ))
        }

        // Remove stale samples for processes that are no longer running
        let livePIDs = Set(newProcesses.map { $0.pid })
        previousSamples = previousSamples.filter { livePIDs.contains($0.key) }
        cpuHistories = cpuHistories.filter { livePIDs.contains($0.key) }

        let sorted = newProcesses.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.processes = sorted }
    }
}
