import AppKit
import Darwin

extension ProcessMonitor {

    /// Two-pass helper folding: accumulates child-process footprints into their
    /// parent app's total, producing the final [MenuBarProcess] array and
    /// patching memoryHistories so sparkline endpoints match the displayed total.
    /// Runs on sampleQueue.
    func foldHelperProcesses(processDict: [pid_t: MenuBarProcess],
                             currentPIDs: [pid_t]) -> [MenuBarProcess] {
        // --- Process Grouping (Folding Helpers) ---
        // Two-pass fold: accumulate child footprints into their parent app's total.
        //
        // Pass 1 — tracked apps: some helpers DO pass the NSRunningApplication /
        // policy filter and land in processDict; fold those and remove from the list.
        //
        // Pass 2 — untracked helpers: most real-world helpers (Chrome Helper,
        // Electron renderers, Safari WebContent, etc.) are filtered out earlier
        // because NSRunningApplication returns nil or they carry .prohibited policy.
        // They never enter processDict, so Pass 1 misses them entirely.
        // We iterate over ALL currentPIDs a second time, skip anything already in
        // processDict, call proc_pid_rusage directly, and fold their footprint in.
        var parentMemBonus: [pid_t: UInt64] = [:]
        var childPIDs: Set<pid_t> = []

        // Pass 1: helpers that made it into processDict
        // Known trade-off: for helpers whose memory is already *shared-accounted*
        // inside the parent's VM space (e.g. certain in-process XPC services),
        // adding their ri_phys_footprint here produces a small overcount.
        // For the common case (Electron renderers, Chrome Helper, Safari WebContent)
        // the processes are fully independent and their footprints are NOT included
        // in the parent's ri_phys_footprint, so folding is correct.
        for pid in processDict.keys {
            if let ppid = ProcessSyscall.getParentPID(of: pid),
               processDict[ppid] != nil {
                parentMemBonus[ppid, default: 0] += processDict[pid]!.memoryFootprintBytes
                childPIDs.insert(pid)
            }
        }

        // Pass 2: helpers that were filtered out (not an app, or .prohibited policy)
        // Each iteration is pooled to release any Swift/ObjC temporaries produced
        // by the withUnsafeMutablePointer / withMemoryRebound closure machinery.
        // No temporary collections are built here — parentMemBonus is updated in place.
        for pid in currentPIDs {
            autoreleasepool {
                guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
                guard processDict[pid] == nil else { return }  // already handled in pass 1

                guard let ppid = ProcessSyscall.getParentPID(of: pid),
                      processDict[ppid] != nil else { return }

                var rusageInfo = rusage_info_v4()
                let rusageRet = withUnsafeMutablePointer(to: &rusageInfo) { ptr in
                    ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
                    }
                }
                guard rusageRet == 0 else { return }
                parentMemBonus[ppid, default: 0] += rusageInfo.ri_phys_footprint
            }
        }

        // Build the final result array, excluding folded children.
        // Pre-size to avoid incremental buffer copies.
        var newProcesses: [MenuBarProcess] = []
        newProcesses.reserveCapacity(max(0, processDict.count - childPIDs.count))

        for (pid, proc) in processDict where !childPIDs.contains(pid) {
            if let bonus = parentMemBonus[pid] {
                let combinedBytes = proc.memoryFootprintBytes + bonus
                let combinedMB    = Double(combinedBytes) / 1_048_576.0

                // Patch the last sample in memoryHistories so that:
                //   (a) the sparkline's final data point matches the displayed value, and
                //   (b) future ticks inherit the folded baseline rather than the raw one.
                // Without this, the sparkline endpoint and the current-value label
                // would show different numbers for any app with active helpers.
                if var hist = memoryHistories[pid], !hist.isEmpty {
                    hist[hist.count - 1] = combinedMB
                    memoryHistories[pid] = hist
                }

                // Recreate the snapshot with the adjusted total memory so that the
                // UI shows the true combined footprint of the app + its helpers.
                newProcesses.append(MenuBarProcess(
                    pid: proc.pid,
                    name: proc.name,
                    bundleIdentifier: proc.bundleIdentifier,
                    icon: proc.icon,
                    cpuFraction: proc.cpuFraction,
                    cpuHistory: proc.cpuHistory,
                    memoryHistory: memoryHistories[pid] ?? proc.memoryHistory,
                    memoryFootprintBytes: combinedBytes,
                    thermalState: proc.thermalState,
                    launchDate: proc.launchDate
                ))
            } else {
                newProcesses.append(proc)
            }
        }

        return newProcesses
    }
}
