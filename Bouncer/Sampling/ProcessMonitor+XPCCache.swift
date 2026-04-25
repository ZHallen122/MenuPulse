import AppKit
import Darwin

extension ProcessMonitor {

    /// Prunes the per-PID static-property XPC cache of entries whose PIDs
    /// are no longer active, and drops CPU/memory history for dead PIDs.
    /// Runs on sampleQueue.
    func pruneStaleCaches(livePIDs: Set<pid_t>, activePIDs: Set<pid_t>) {
        previousSamples = previousSamples.filter { livePIDs.contains($0.key) }
        cpuHistories = cpuHistories.filter { livePIDs.contains($0.key) }
        memoryHistories = memoryHistories.filter { livePIDs.contains($0.key) }

        let deadPIDs = Set(appStaticCache.keys).subtracting(activePIDs)
        for deadPid in deadPIDs {
            appStaticCache.removeValue(forKey: deadPid)
        }
    }
}
