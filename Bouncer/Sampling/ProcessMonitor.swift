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

    /// Raw list of processes updated every tick, regardless of UI visibility.
    /// Used by background observers (e.g. SwapMonitor) without triggering UI renders.
    private(set) var currentProcesses: [MenuBarProcess] = []

    /// Whether the UI is currently visible (Popover or HUD is open).
    /// Updated by AppDelegate to prevent unnecessary `@Published` state mutations.
    var isUIVisible: Bool = false {
        didSet {
            if isUIVisible && !oldValue {
                self.processes = self.currentProcesses
            }
        }
    }

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

    /// Maps bundleID → current lifecycle phase string for all running apps.
    /// Updated on the main queue on each persist tick.
    @Published var bundleIDPhases: [String: String] = [:]

    /// Bundle IDs currently in a per-app learning period. Derived from `bundleIDPhases`.
    var learningBundleIDs: Set<String> {
        Set(bundleIDPhases.filter { $0.value.hasPrefix("learning_") }.keys)
    }

    /// Maps bundleID → appName for apps whose version changed since last seen.
    /// Accumulates entries over time; HUDView manages dismissal via a local @State var.
    @Published var recentlyUpdatedApps: [String: String] = [:]

    private let prefs: PreferencesManager
    private var timer: Timer?
    let dataStore: DataStore
    internal var lastPersistTime: Date = .distantPast

    /// Set externally by AppDelegate to enable anomaly detection and notifications.
    var anomalyDetector: AnomalyDetector?

    /// Maps each PID to its last-observed accumulated CPU nanoseconds and the
    /// wall-clock nanoseconds (`DispatchTime.now().uptimeNanoseconds`) at
    /// sample time. Used to compute per-interval CPU delta fractions.
    var previousSamples: [pid_t: (cpuNanos: UInt64, wallNanos: UInt64)] = [:]

    /// Rolling CPU fraction history keyed by PID. Each entry is capped at 20
    /// samples; older entries are dropped as new ones arrive. Pruned when a
    /// process is no longer running.
    var cpuHistories: [pid_t: [Double]] = [:]

    /// Rolling memory footprint history (MB) keyed by PID. Capped at 20 samples.
    var memoryHistories: [pid_t: [Double]] = [:]

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

    // MARK: - Static app property cache (accessed only on sampleQueue)

    struct AppStaticProperties {
        let name: String
        let bundleIdentifier: String?
        let bundleURL: URL?
        let icon: NSImage?
        let launchDate: Date?
        let activationPolicy: NSApplication.ActivationPolicy
    }

    enum AppStaticCacheResult {
        case notAnApp
        case app(AppStaticProperties)
    }

    /// Per-PID cache of static NSRunningApplication properties (don't change for a given PID).
    /// Populated on first encounter; pruned when the PID disappears from livePIDs.
    var appStaticCache: [pid_t: AppStaticCacheResult] = [:]

    // MARK: - Per-app lifecycle cache (accessed only on sampleQueue)

    internal struct LifecycleEntry {
        var state: String
        var version: String?
        var learningStartedAt: Date?
        var lastSeen: Date
    }

    /// In-memory cache of per-app lifecycle state. Keyed by bundle ID.
    /// Populated lazily from DataStore on first encounter; updated on each persist tick.
    internal var lifecycleCache: [String: LifecycleEntry] = [:]

    /// Phase map updated on each persist tick and passed to AnomalyDetector.
    /// Accessed only on sampleQueue.
    private var currentBundleIDPhases: [String: String] = [:]

    init(prefs: PreferencesManager = PreferencesManager(), dataStore: DataStore = DataStore()) {
        self.prefs = prefs
        self.dataStore = dataStore
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

        let currentPIDs = getActivePIDsFast()
        let activePIDsSet = Set(currentPIDs)
        var bundleURLMap: [String: URL] = [:]

        let processDict = buildProcessDict(currentPIDs: currentPIDs,
                                           thermalState: thermalState,
                                           wallNow: wallNow,
                                           bundleURLMap: &bundleURLMap)

        let newProcesses = foldHelperProcesses(processDict: processDict, currentPIDs: currentPIDs)

        // Prune stale state for PIDs that are no longer running.
        // Use the full processDict keyset (includes folded children) so that
        // CPU-delta state is preserved for helper processes between ticks.
        let livePIDs = Set(processDict.keys)
        pruneStaleCaches(livePIDs: livePIDs, activePIDs: activePIDsSet)

        // No need to sort here, ProcessListViewModel sorts it later.
        let sorted = newProcesses

        // Persist samples and advance per-app lifecycle state on a throttled interval.
        persistAndAdvanceLifecycle(processes: sorted, bundleURLMap: bundleURLMap)

        let cpuFrac = sampleSystemCPU()
        let (ramUsed, ramTotal, pressure) = sampleSystemRAM()

        let capturedPhaseSnapshot = currentBundleIDPhases
        anomalyDetector?.evaluate(processes: sorted, pressure: pressure,
                                   bundleIDPhases: capturedPhaseSnapshot)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentProcesses = sorted

            // Limit SwiftUI objectWillChange firings by doing equality checks
            if self.isUIVisible {
                self.processes = sorted
                if self.systemCPUFraction != cpuFrac { self.systemCPUFraction = cpuFrac }
                if self.systemRAMUsedBytes != ramUsed { self.systemRAMUsedBytes = ramUsed }
                if self.systemRAMTotalBytes != ramTotal { self.systemRAMTotalBytes = ramTotal }
                if self.memoryPressure != pressure { self.memoryPressure = pressure }
            } else {
                // When UI is hidden, throttle memory updates to only when menu bar % changes
                if self.memoryPressure != pressure { self.memoryPressure = pressure }

                if ramTotal > 0 && self.systemRAMTotalBytes > 0 {
                    let oldPerc = Int((Double(self.systemRAMUsedBytes) / Double(self.systemRAMTotalBytes) * 100).rounded())
                    let newPerc = Int((Double(ramUsed) / Double(ramTotal) * 100).rounded())
                    if oldPerc != newPerc {
                        self.systemRAMUsedBytes = ramUsed
                        self.systemRAMTotalBytes = ramTotal
                    }
                } else {
                    if self.systemRAMUsedBytes != ramUsed { self.systemRAMUsedBytes = ramUsed }
                    if self.systemRAMTotalBytes != ramTotal { self.systemRAMTotalBytes = ramTotal }
                }
            }
        }
    }

    // MARK: - Lifecycle persistence

    /// Persists process samples and advances per-app lifecycle phases.
    ///
    /// Runs on a throttled interval (30 s normally, 5 s in testing mode). Extracted
    /// from `sampleOnQueue()` for readability; must only be called from `sampleQueue`.
    internal func persistAndAdvanceLifecycle(processes: [MenuBarProcess], bundleURLMap: [String: URL]) {
        let persistInterval: TimeInterval = prefs.testingMode ? 5 : 30
        guard Date().timeIntervalSince(lastPersistTime) >= persistInterval else { return }

        dataStore.persistSamples(processes)
        dataStore.purgeOldSamples()
        // Skip baseline recomputation in testing mode so the baseline stays frozen
        // at pre-test levels; otherwise the baseline chases the spike and the
        // anomaly multiplier threshold is never reached.
        if !prefs.testingMode {
            dataStore.recomputeBaselines()
        }
        lastPersistTime = Date()

        // --- Per-app lifecycle management (section 6.6) ---
        let now = Date()
        let staleCutoff = now.addingTimeInterval(-30 * 24 * 3600)
        dataStore.markStaleApps(lastSeenCutoff: staleCutoff)

        var newUpdatesThisCycle: [String: String] = [:]

        for process in processes {
            guard let bundleID = process.bundleIdentifier else { continue }

            // Resolve current version from Info.plist via the running app's bundle.
            let version: String? = bundleURLMap[bundleID].flatMap { url in
                Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
            }

            if var cached = lifecycleCache[bundleID] {
                // Update cache timestamp for all running apps so they aren't evicted while active
                cached.lastSeen = now
                lifecycleCache[bundleID] = cached

                // App is known to us — check for version change or stale return.
                // Ignored apps are exempt from all automatic state transitions:
                // a user-curated ignore list must not be silently cleared by an update or dormancy.
                if cached.state == "ignored" {
                    // No-op: stay ignored regardless of version change or stale flag.
                } else if let newVer = version, let cachedVer = cached.version, newVer != cachedVer {
                    // Version changed: reset to learning_phase_1, announce update.
                    dataStore.resetToLearning(bundleID: bundleID, version: version)
                    cached = LifecycleEntry(state: "learning_phase_1", version: version, learningStartedAt: now, lastSeen: now)
                    lifecycleCache[bundleID] = cached
                    newUpdatesThisCycle[bundleID] = process.name
                } else if cached.state == "stale" {
                    // App returning after a long absence: re-enter learning.
                    dataStore.resetToLearning(bundleID: bundleID, version: version)
                    cached = LifecycleEntry(state: "learning_phase_1",
                                            version: version ?? cached.version,
                                            learningStartedAt: now,
                                            lastSeen: now)
                    lifecycleCache[bundleID] = cached
                }
            } else {
                // New to cache: query DataStore to see if we've seen this app before.
                if let entry = dataStore.lifecycleEntry(for: bundleID) {
                    if entry.state == "ignored" {
                        // Already ignored in DB (e.g., app restarted): restore ignored state.
                        lifecycleCache[bundleID] = LifecycleEntry(state: "ignored",
                                                                   version: entry.version,
                                                                   learningStartedAt: nil,
                                                                   lastSeen: now)
                    } else if entry.state == "stale" {
                        // Known but dormant: restart learning clock.
                        dataStore.resetToLearning(bundleID: bundleID, version: version)
                        lifecycleCache[bundleID] = LifecycleEntry(state: "learning_phase_1",
                                                                   version: version ?? entry.version,
                                                                   learningStartedAt: now,
                                                                   lastSeen: now)
                    } else {
                        lifecycleCache[bundleID] = LifecycleEntry(state: entry.state,
                                                                   version: entry.version,
                                                                   learningStartedAt: entry.learningStartedAt,
                                                                   lastSeen: now)
                    }
                } else {
                    // Brand new app: start learning clock now.
                    dataStore.resetToLearning(bundleID: bundleID, version: version)
                    lifecycleCache[bundleID] = LifecycleEntry(state: "learning_phase_1",
                                                               version: version,
                                                               learningStartedAt: now,
                                                               lastSeen: now)
                }
            }

            // Always persist last_seen_at + current state.
            let entry = lifecycleCache[bundleID]!
            dataStore.updateAppLifecycle(bundleID: bundleID,
                                         state: entry.state,
                                         version: entry.version ?? version,
                                         lastSeen: now)
        }

        // Advance phases based on elapsed time since learning_started_at.
        // Compute target phase directly from elapsed time — no step-by-step iteration.
        var newPhaseMap: [String: String] = [:]
        for bundleID in lifecycleCache.keys {
            guard var entry = lifecycleCache[bundleID] else { continue }
            guard entry.state.hasPrefix("learning_") else {
                // Non-learning states (active, ignored, stale) pass through unchanged.
                newPhaseMap[bundleID] = entry.state
                continue
            }
            let startedAt = entry.learningStartedAt ?? now
            let elapsed = now.timeIntervalSince(startedAt)
            let targetPhase: String
            if elapsed < 4 * 3600 {
                targetPhase = "learning_phase_1"
            } else if elapsed < 24 * 3600 {
                targetPhase = "learning_phase_2"
            } else if elapsed < 3 * 86400 {
                targetPhase = "learning_phase_3"
            } else {
                targetPhase = "active"
            }
            if targetPhase != entry.state {
                entry.state = targetPhase
                lifecycleCache[bundleID] = entry
                dataStore.updateAppLifecycle(bundleID: bundleID,
                                             state: targetPhase,
                                             version: entry.version,
                                             lastSeen: now)
            }
            newPhaseMap[bundleID] = targetPhase
        }
        // Evict entries not seen in the last 30 days so that when a stale app
        // reappears the cache miss forces a fresh DB lookup (which will see the
        // "stale" state written by markStaleApps) rather than reusing a stale
        // "active" entry.
        let staleEvictCutoff = now.addingTimeInterval(-30 * 24 * 3600)
        lifecycleCache = lifecycleCache.filter { $0.value.lastSeen >= staleEvictCutoff }

        currentBundleIDPhases = newPhaseMap

        // Publish phase map and any new version-change events on the main queue.
        let capturedPhases = newPhaseMap
        let capturedUpdates = newUpdatesThisCycle
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.bundleIDPhases = capturedPhases
            if !capturedUpdates.isEmpty {
                var merged = self.recentlyUpdatedApps
                merged.merge(capturedUpdates) { _, new in new }
                self.recentlyUpdatedApps = merged
            }
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
            let sysRet = sysctlbyname("hw.memsize", &total, &size, nil, 0)
            if sysRet != 0 {
                NSLog("ProcessMonitor: sysctlbyname hw.memsize failed (errno=%d)", errno)
            }
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
