import AppKit
import Darwin

class ProcessMonitor: ObservableObject {
    @Published var processes: [MenuBarProcess] = []
    @Published var systemCPUFraction: Double = 0.0
    @Published var systemRAMUsedBytes: UInt64 = 0
    @Published var systemRAMTotalBytes: UInt64 = 0

    private let prefs: PreferencesManager
    private var timer: Timer?
    // pid -> (accumulated CPU nanoseconds, wall-clock nanoseconds)
    private var previousSamples: [pid_t: (cpuNanos: UInt64, wallNanos: UInt64)] = [:]
    // pid -> rolling CPU history (last 20 samples)
    private var cpuHistories: [pid_t: [Double]] = [:]
    // System-wide CPU tick tracking
    private var previousCPUTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    // Total physical RAM cached after first read
    private var cachedTotalRAMBytes: UInt64 = 0

    init(prefs: PreferencesManager = PreferencesManager()) {
        self.prefs = prefs
    }

    func startMonitoring() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: prefs.refreshInterval, repeats: true) { [weak self] _ in
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

        let cpuFrac = sampleSystemCPU()
        let (ramUsed, ramTotal) = sampleSystemRAM()

        DispatchQueue.main.async {
            self.processes = sorted
            self.systemCPUFraction = cpuFrac
            self.systemRAMUsedBytes = ramUsed
            self.systemRAMTotalBytes = ramTotal
        }
    }

    // MARK: - System-wide stats

    private func sampleSystemCPU() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        let user = cpuInfo.cpu_ticks.0
        let sys  = cpuInfo.cpu_ticks.1
        let idle = cpuInfo.cpu_ticks.2
        let nice = cpuInfo.cpu_ticks.3

        var result: Double = 0
        if let prev = previousCPUTicks {
            let du = Double(user &- prev.user)
            let ds = Double(sys  &- prev.sys)
            let di = Double(idle &- prev.idle)
            let dn = Double(nice &- prev.nice)
            let total = du + ds + di + dn
            if total > 0 {
                result = min((du + ds + dn) / total, 1.0)
            }
        }
        previousCPUTicks = (user: user, sys: sys, idle: idle, nice: nice)
        return result
    }

    private func sampleSystemRAM() -> (used: UInt64, total: UInt64) {
        if cachedTotalRAMBytes == 0 {
            var total: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            sysctlbyname("hw.memsize", &total, &size, nil, 0)
            cachedTotalRAMBytes = total
        }

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, cachedTotalRAMBytes) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = UInt64(pageSize)

        let usedPages = UInt64(vmStats.active_count)
            + UInt64(vmStats.wire_count)
            + UInt64(vmStats.compressor_page_count)
        let usedBytes = usedPages * ps

        return (usedBytes, cachedTotalRAMBytes)
    }
}
