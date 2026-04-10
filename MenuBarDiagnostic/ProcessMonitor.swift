import AppKit
import Darwin

/// Sampling engine that periodically queries all user-visible processes
/// (regular and accessory; excludes background-only daemons with `.prohibited` policy)
/// and publishes per-process and system-wide CPU/RAM metrics.
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

    /// Current system memory pressure derived from available page ratios.
    /// Updated each sample tick alongside other published stats.
    @Published var memoryPressure: MemoryPressure = .normal

    /// Total physical RAM installed, read once via `sysctlbyname("hw.memsize")`
    /// and cached for the lifetime of the monitor.
    @Published var systemRAMTotalBytes: UInt64 = 0

    private let prefs: PreferencesManager
    private var timer: Timer?
    let dataStore = DataStore()
    private var lastPersistTime: Date = .distantPast

    /// Set externally by AppDelegate to enable anomaly detection and notifications.
    var anomalyDetector: AnomalyDetector?

    /// Maps each PID to its last-observed accumulated CPU nanoseconds and the
    /// wall-clock nanoseconds (`DispatchTime.now().uptimeNanoseconds`) at
    /// sample time. Used to compute per-interval CPU delta fractions.
    private var previousSamples: [pid_t: (cpuNanos: UInt64, wallNanos: UInt64)] = [:]

    /// Rolling CPU fraction history keyed by PID. Each entry is capped at 20
    /// samples; older entries are dropped as new ones arrive. Pruned when a
    /// process is no longer running.
    private var cpuHistories: [pid_t: [Double]] = [:]

    /// Rolling memory footprint history (MB) keyed by PID. Capped at 20 samples.
    private var memoryHistories: [pid_t: [Double]] = [:]

    /// Last-seen CPU tick counters from `host_statistics(HOST_CPU_LOAD_INFO)`.
    /// `nil` on the first sample; a non-nil value enables delta computation
    /// on subsequent samples.
    private var previousCPUTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    /// Physical RAM total in bytes, populated on first call to `sampleSystemRAM()`
    /// and reused on every subsequent call to avoid repeated `sysctlbyname` calls.
    private var cachedTotalRAMBytes: UInt64 = 0

    /// Dedicated serial queue for all sampling work (syscalls + history mutation).
    /// Keeps every access to previousSamples / cpuHistories / memoryHistories
    /// off the main thread and serialised, avoiding data races.
    private let sampleQueue = DispatchQueue(label: "com.bouncer.sampling", qos: .utility)

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

    /// Performs a single sampling pass off the main thread.
    ///
    /// Dispatches all syscalls (`proc_pidinfo`, `proc_pid_rusage`, `host_statistics64`)
    /// to `sampleQueue` (a `.utility` serial queue) so that the main thread — and
    /// therefore the UI — is never blocked by the loop. Results are published back
    /// on the main queue once the pass is complete.
    private func sample() {
        sampleQueue.async { [weak self] in
            self?.sampleOnQueue()
        }
    }

    private func sampleOnQueue() {
        let thermalState = ProcessInfo.processInfo.thermalState
        let wallNow = DispatchTime.now().uptimeNanoseconds

        // Include all user-visible processes (regular and accessory; excludes
        // background-only daemons with `.prohibited` policy).
        let accessoryApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited
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

            // Read physical memory footprint via proc_pid_rusage (more accurate than
            // pti_resident_size; matches Activity Monitor's "Memory" column).
            //
            // Pointer bridging: proc_pid_rusage expects a rusage_info_t* (pointer-to-pointer).
            // We must rebind rusageInfo's own address to that type so the C function writes
            // directly into our struct — NOT into a local pointer variable (&voidPtr), which
            // is only 8 bytes and causes a stack-smashing SIGABRT.
            var rusageInfo = rusage_info_v4()
            let rusageRet = withUnsafeMutablePointer(to: &rusageInfo) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
                }
            }
            let memFootprint: UInt64 = (rusageRet == 0) ? rusageInfo.ri_phys_footprint : 0

            // Maintain a rolling window of the last 20 memory footprint samples (in MB).
            var memHistory = memoryHistories[pid] ?? []
            memHistory.append(Double(memFootprint) / 1_048_576.0)
            if memHistory.count > 20 { memHistory.removeFirst(memHistory.count - 20) }
            memoryHistories[pid] = memHistory

            newProcesses.append(MenuBarProcess(
                pid: pid,
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                cpuFraction: cpuFraction,
                cpuHistory: history,
                memoryHistory: memHistory,
                memoryFootprintBytes: memFootprint,
                thermalState: thermalState,
                launchDate: app.launchDate
            ))
        }

        // Prune stale state for PIDs that are no longer running.
        let livePIDs = Set(newProcesses.map { $0.pid })
        previousSamples = previousSamples.filter { livePIDs.contains($0.key) }
        cpuHistories = cpuHistories.filter { livePIDs.contains($0.key) }
        memoryHistories = memoryHistories.filter { livePIDs.contains($0.key) }

        let sorted = newProcesses.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if Date().timeIntervalSince(lastPersistTime) >= 30 {
            dataStore.persistSamples(sorted)
            dataStore.purgeOldSamples()
            dataStore.recomputeBaselines()
            lastPersistTime = Date()
        }

        let cpuFrac = sampleSystemCPU()
        let (ramUsed, ramTotal, pressure) = sampleSystemRAM()

        anomalyDetector?.evaluate(processes: sorted, pressure: pressure)

        DispatchQueue.main.async {
            self.processes = sorted
            self.systemCPUFraction = cpuFrac
            self.systemRAMUsedBytes = ramUsed
            self.systemRAMTotalBytes = ramTotal
            self.memoryPressure = pressure
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

    /// Returns `(usedBytes, totalBytes, pressure)` for system RAM.
    ///
    /// - **Total** is read once from `sysctlbyname("hw.memsize")` and cached in
    ///   `cachedTotalRAMBytes` for all future calls.
    /// - **Used** is computed as `(active + wired + compressor) × pageSize`,
    ///   which matches the "used" figure shown in Activity Monitor.
    /// - **Pressure** is derived from the available-page ratio
    ///   `(free + inactive + purgeable) / totalPages`:
    ///   `.normal` > 25 %, `.warning` > 10 %, `.critical` ≤ 10 %.
    ///
    /// Returns `(0, cachedTotalRAMBytes, .normal)` if `host_statistics64` fails.
    private func sampleSystemRAM() -> (used: UInt64, total: UInt64, pressure: MemoryPressure) {
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
        guard kr == KERN_SUCCESS else { return (0, cachedTotalRAMBytes, .normal) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = UInt64(pageSize)

        let usedPages = UInt64(vmStats.active_count)
            + UInt64(vmStats.wire_count)
            + UInt64(vmStats.compressor_page_count)
        let usedBytes = usedPages * ps

        // Compute memory pressure from the ratio of available pages to total pages.
        let free      = UInt64(vmStats.free_count)
        let inactive  = UInt64(vmStats.inactive_count)
        let purgeable = UInt64(vmStats.purgeable_count)
        let totalPages = ps > 0 ? cachedTotalRAMBytes / ps : 1
        let availableRatio = Double(free + inactive + purgeable) / Double(totalPages)
        let pressure: MemoryPressure = availableRatio > 0.25 ? .normal
                                     : availableRatio > 0.10 ? .warning
                                     : .critical

        return (usedBytes, cachedTotalRAMBytes, pressure)
    }
}
