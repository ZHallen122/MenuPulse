import AppKit
import Darwin

extension ProcessMonitor {

    func getActivePIDsFast() -> [pid_t] {
        let type = UInt32(PROC_ALL_PIDS)
        let bufferSize = proc_listpids(type, 0, nil, 0)
        let paddedSize = bufferSize + Int32(MemoryLayout<pid_t>.stride * 50)
        guard paddedSize > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(paddedSize) / MemoryLayout<pid_t>.stride)
        let bytesRead = proc_listpids(type, 0, &pids, paddedSize)
        guard bytesRead > 0 else { return [] }

        let actualCount = Int(bytesRead) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(actualCount))
    }

    /// Builds the per-PID MenuBarProcess dict, using/populating appStaticCache,
    /// filtering .prohibited apps and the self PID, and updating
    /// previousSamples / cpuHistories / memoryHistories as a side effect.
    /// Runs on sampleQueue.
    func buildProcessDict(currentPIDs: [pid_t],
                          thermalState: ProcessInfo.ThermalState,
                          wallNow: UInt64,
                          bundleURLMap: inout [String: URL]) -> [pid_t: MenuBarProcess] {
        // Keyed by PID for O(1) parent lookup during the grouping pass below.
        // Pre-sized to the current PID count to avoid incremental reallocations.
        var processDict: [pid_t: MenuBarProcess] = [:]
        processDict.reserveCapacity(currentPIDs.count)

        for pid in currentPIDs {
            // Each iteration is wrapped in its own pool so ObjC temporaries created
            // by NSRunningApplication (icon, localizedName, bundleURL, etc.) are
            // released immediately rather than accumulating until the loop exits.
            autoreleasepool {
                guard pid > 0 else { return }
                guard pid != ProcessInfo.processInfo.processIdentifier else { return }

                // --- Strict IPC Guard ---
                // NSRunningApplication(processIdentifier:) crosses an XPC boundary and is
                // expensive. Only call it when the PID is NOT already in the static-info
                // cache; every subsequent tick reads directly from the dictionary.
                let staticProps: AppStaticProperties
                if let result = appStaticCache[pid] {
                    switch result {
                    case .notAnApp: return
                    case .app(let props): staticProps = props
                    }
                } else {
                    guard let app = NSRunningApplication(processIdentifier: pid) else {
                        appStaticCache[pid] = .notAnApp
                        return
                    }
                    let props = AppStaticProperties(
                        name: app.localizedName ?? "Unknown",
                        bundleIdentifier: app.bundleIdentifier,
                        bundleURL: app.bundleURL,
                        icon: app.icon,
                        launchDate: app.launchDate,
                        activationPolicy: app.activationPolicy
                    )
                    appStaticCache[pid] = .app(props)
                    staticProps = props
                }

                // Exclude background-only daemons with `.prohibited` policy
                guard staticProps.activationPolicy != .prohibited else { return }

                if let bid = staticProps.bundleIdentifier, let url = staticProps.bundleURL {
                    bundleURLMap[bid] = url
                }

                var info = proc_taskinfo()
                let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
                let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize)
                guard ret == infoSize else {
                    // ret == 0 with errno ESRCH or EPERM means the process just exited —
                    // normal race between runningApplications and actual exit; skip silently.
                    let e = errno
                    if ret != 0 || (e != ESRCH && e != EPERM) {
                        NSLog("ProcessMonitor: proc_pidinfo failed for pid %d (ret=%d, errno=%d); skipping", pid, ret, e)
                    }
                    return
                }

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
                guard rusageRet == 0 else {
                    NSLog("ProcessMonitor: proc_pid_rusage failed for pid %d (rc=%d); skipping sample", pid, rusageRet)
                    return
                }
                let memFootprint: UInt64 = rusageInfo.ri_phys_footprint

                // Maintain a rolling window of the last 20 memory footprint samples (in MB).
                var memHistory = memoryHistories[pid] ?? []
                memHistory.append(Double(memFootprint) / 1_048_576.0)
                if memHistory.count > 20 { memHistory.removeFirst(memHistory.count - 20) }
                memoryHistories[pid] = memHistory

                processDict[pid] = MenuBarProcess(
                    pid: pid,
                    name: staticProps.name,
                    bundleIdentifier: staticProps.bundleIdentifier,
                    icon: staticProps.icon,
                    cpuFraction: cpuFraction,
                    cpuHistory: history,
                    memoryHistory: memHistory,
                    memoryFootprintBytes: memFootprint,
                    thermalState: thermalState,
                    launchDate: staticProps.launchDate
                )
            }
        }

        return processDict
    }
}
