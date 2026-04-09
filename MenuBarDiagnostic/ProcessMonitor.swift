import AppKit
import Darwin

/// Sampling engine that periodically queries every running menu-bar process
/// (activation policy `.accessory`) and publishes per-process and system-wide
/// CPU/RAM metrics.
///
/// Sampling is driven by a repeating `Timer` whose interval is read from
/// `PreferencesManager.refreshInterval`. All published updates are dispatched
/// to the main queue so SwiftUI views can bind directly.
class ProcessMonitor: ObservableObject {

    /// Snapshot of all currently running menu-bar processes, sorted
    /// alphabetically by name. Updated on the main queue after each sample tick.
    @Published var processes: [MenuBarProcess] = []

    /// System-wide CPU utilisation as a fraction in `[0, 1]`, computed from
    /// `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas (user + sys + nice).
    /// Returns `0` until the second sample, when a delta can be calculated.
    @Published var systemCPUFraction: Double = 0.0

    /// Bytes of RAM currently in use (active + wired + compressor pages × page size).
    @Published var systemRAMUsedBytes: UInt64 = 0

    /// Total physical RAM installed, read once via `sysctlbyname("hw.memsize")`
    /// and cached for the lifetime of the monitor.
    @Published var systemRAMTotalBytes: UInt64 = 0

    private let prefs: PreferencesManager
    private var timer: Timer?

    /// Maps each PID to its last-observed accumulated CPU nanoseconds and the
    /// wall-clock nanoseconds (`DispatchTime.now().uptimeNanoseconds`) at
    /// sample time. Used to compute per-interval CPU delta fractions.
    private var previousSamples: [pid_t: (cpuNanos: UInt64, wallNanos: UInt64)] = [:]

    /// Rolling CPU fraction history keyed by PID. Each entry is capped at 20
    /// samples; older entries are dropped as new ones arrive. Pruned when a
    /// process is no longer running.
    private var cpuHistories: [pid_t: [Double]] = [:]

    /// Last-seen CPU tick counters from `host_statistics(HOST_CPU_LOAD_INFO)`.
    /// `nil` on the first sample; a non-nil value enables delta computation
    /// on subsequent samples.
    private var previousCPUTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    /// Physical RAM total in bytes, populated on first call to `sampleSystemRAM()`
    /// and reused on every subsequent call to avoid repeated `sysctlbyname` calls.
    private var cachedTotalRAMBytes: UInt64 = 0

    init(prefs: PreferencesManager = PreferencesManager()) {
        self.prefs = prefs
    }

    deinit { stopMonitoring() }

    /// Starts the sampling timer.
    ///
    /// Calls `sample()` immediately for an instant first reading, then
    /// schedules a repeating timer at `prefs.refreshInterval` seconds.
    func startMonitoring() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: prefs.refreshInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    /// Stops the sampling timer and releases it.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Performs a single sampling pass: queries every accessory-policy process
    /// via `proc_pidinfo`, computes CPU deltas and CPU history, fetches
    /// system-wide CPU and RAM, then publishes the results on the main queue.
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

            // Accumulated CPU time in nanoseconds (user + kernel threads combined).
            let cpuNow = info.pti_total_user + info.pti_total_system

            var cpuFraction: Double = 0.0
            if let prev = previousSamples[pid] {
                // Guard against clock regression (should not happen, but defensive).
                let cpuDelta = cpuNow >= prev.cpuNanos ? cpuNow - prev.cpuNanos : 0
                // `wallDelta` falls back to 1 ns instead of 0 to avoid division
                // by zero if two samples land on the exact same uptime nanosecond.
                let wallDelta = wallNow > prev.wallNanos ? wallNow - prev.wallNanos : 1
                // Cap at 1.0: on multi-core systems `cpuDelta` can theoretically
                // exceed `wallDelta` if the process saturates more than one core,
                // but we report CPU as a fraction of a single logical core.
                cpuFraction = min(Double(cpuDelta) / Double(wallDelta), 1.0)
            }

            previousSamples[pid] = (cpuNanos: cpuNow, wallNanos: wallNow)

            // Maintain a rolling window of the last 20 CPU fraction samples for sparkline display.
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
                thermalState: thermalState,
                launchDate: app.launchDate
            ))
        }

        // Prune stale state for PIDs that are no longer running.
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

    /// Returns the system-wide CPU utilisation as a fraction in `[0, 1]`.
    ///
    /// Uses wrapping arithmetic (`&-`) when subtracting tick counters to handle
    /// the `UInt32` rollover that occurs on very long-running systems. Returns
    /// `0` on the first call (no previous sample to delta against) or when
    /// `host_statistics` fails.
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

    /// Returns `(usedBytes, totalBytes)` for system RAM.
    ///
    /// - **Total** is read once from `sysctlbyname("hw.memsize")` and cached in
    ///   `cachedTotalRAMBytes` for all future calls.
    /// - **Used** is computed as `(active + wired + compressor) × pageSize`,
    ///   which matches the "used" figure shown in Activity Monitor. Free and
    ///   inactive pages are excluded.
    ///
    /// Returns `(0, cachedTotalRAMBytes)` if `host_statistics64` fails.
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
