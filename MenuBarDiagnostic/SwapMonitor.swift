import Foundation
import Combine
import UserNotifications
import Darwin

/// Represents the current swap/compressed memory activity level on the system,
/// derived from 5-minute rolling-window deltas — not absolute values.
///
/// The correct mental model: Swap absolute value = how much was written in the past.
/// Swap delta = what is happening right now. Only the delta reflects real-time I/O pressure.
enum SwapState: Equatable {
    /// Swap delta is ~0 over the last 5 minutes. Normal operation, no icon change.
    case normal
    /// Compressed memory increased 300 MB+ in the last 5 minutes. Yellow icon, no notification.
    case compressedGrowing
    /// Swap increased 100–499 MB in the last 5 minutes. Yellow icon, no notification.
    case swapMinor
    /// Swap increased 500 MB–999 MB in the last 5 minutes. Orange icon, notification with culprit name.
    case swapSignificant
    /// Swap increased 1 GB+ in the last 5 minutes. Red icon, urgent notification.
    case swapCritical
}

/// Monitors system swap memory and compressed memory usage by polling every 30 seconds.
///
/// Uses a 5-minute rolling window of `(timestamp, bytes)` samples to compute deltas.
/// Only posts a `UNUserNotification` on `swapSignificant` or `swapCritical` (1-hour cooldown).
class SwapMonitor: ObservableObject {
    @Published var swapUsedBytes: UInt64 = 0
    @Published var swapTotalBytes: UInt64 = 0
    @Published var compressedBytes: UInt64 = 0
    @Published var swapState: SwapState = .normal

    /// Closure that returns the current process list for notification body.
    var topProcessProvider: (() -> [MenuBarProcess])? = nil

    /// Exposed for unit tests to verify cooldown logic.
    var lastSwapNotificationDate: Date? = nil

    // Rolling window samples: (timestamp, bytes)
    private var swapSamples: [(timestamp: Date, bytes: UInt64)] = []
    private var compressedSamples: [(timestamp: Date, bytes: UInt64)] = []
    private let windowDuration: TimeInterval = 5 * 60  // 5 minutes

    private var timer: DispatchSourceTimer?
    private let sampleQueue = DispatchQueue(label: "com.bouncer.swapmonitor", qos: .utility)

    func startMonitoring() {
        let source = DispatchSource.makeTimerSource(queue: sampleQueue)
        source.schedule(deadline: .now(), repeating: 30)
        source.setEventHandler { [weak self] in
            self?.sample()
        }
        source.resume()
        timer = source
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Internal / Testable API

    /// Injects a swap + compressed sample at a given timestamp. For unit tests only.
    func injectSample(swapBytes: UInt64, compressedBytes injectedCompressedBytes: UInt64, at timestamp: Date = Date()) {
        swapSamples.append((timestamp: timestamp, bytes: swapBytes))
        compressedSamples.append((timestamp: timestamp, bytes: injectedCompressedBytes))
        trimWindow()
        swapUsedBytes = swapBytes
        compressedBytes = injectedCompressedBytes
        refreshSwapState()
    }

    /// Builds notification content for the given state. Exposed for unit tests.
    func buildNotificationContent(processes: [MenuBarProcess], state: SwapState) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if state == .swapCritical {
            content.title = "Critical: Mac is actively swapping to disk"
            content.body = buildNotificationBody(processes: processes, urgent: true)
        } else {
            content.title = "Your Mac is using disk as memory"
            content.body = buildNotificationBody(processes: processes, urgent: false)
        }
        content.categoryIdentifier = "SWAP_ACTIVE"
        content.sound = .default
        return content
    }

    /// Convenience overload using the current swapState. Exposed for unit tests.
    func buildNotificationContent(processes: [MenuBarProcess]) -> UNMutableNotificationContent {
        buildNotificationContent(processes: processes, state: swapState)
    }

    /// Returns true if the notification was enqueued (cooldown not active).
    /// Exposed for unit tests; does NOT actually post in XCTest environment.
    @discardableResult
    func checkAndMaybeNotify(processes: [MenuBarProcess]) -> Bool {
        if let last = lastSwapNotificationDate, Date().timeIntervalSince(last) < 3600 { return false }
        lastSwapNotificationDate = Date()

        // Skip actual delivery in XCTest environment.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            let content = buildNotificationContent(processes: processes, state: swapState)
            let request = UNNotificationRequest(
                identifier: "swap-active",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("SwapMonitor: failed to schedule notification: %@", error.localizedDescription)
                }
            }
        }
        return true
    }

    // MARK: - Private

    private func sample() {
        // Read swap usage via sysctl
        var swapInfo = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swapInfo, &size, nil, 0) != 0 {
            NSLog("SwapMonitor: sysctlbyname vm.swapusage failed (errno=%d)", errno)
            return
        }

        // Read compressed memory via HOST_VM_INFO64
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { statsPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, statsPtr, &count)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let compressed: UInt64 = kr == KERN_SUCCESS
            ? UInt64(vmStats.compressor_page_count) * pageSize
            : 0

        let now = Date()
        let swapUsed = swapInfo.xsu_used
        let swapTotal = swapInfo.xsu_total

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.swapSamples.append((timestamp: now, bytes: swapUsed))
            self.compressedSamples.append((timestamp: now, bytes: compressed))
            self.trimWindow()
            self.swapUsedBytes = swapUsed
            self.swapTotalBytes = swapTotal
            self.compressedBytes = compressed
            self.refreshSwapState()

            // Notify only on significant or critical swap growth (1-hour cooldown).
            if self.swapState == .swapSignificant || self.swapState == .swapCritical {
                let processes = self.topProcessProvider?() ?? []
                self.checkAndMaybeNotify(processes: processes)
            }
        }
    }

    /// Removes samples older than `windowDuration` before the most recent sample timestamp.
    private func trimWindow() {
        let latestSwap = swapSamples.last?.timestamp ?? Date.distantPast
        let latestCompressed = compressedSamples.last?.timestamp ?? Date.distantPast
        let latestTime = max(latestSwap, latestCompressed)
        let cutoff = latestTime.addingTimeInterval(-windowDuration)
        swapSamples.removeAll { $0.timestamp < cutoff }
        compressedSamples.removeAll { $0.timestamp < cutoff }
    }

    private func swapDelta() -> UInt64 {
        guard swapSamples.count >= 2 else { return 0 }
        let oldest = swapSamples.first!.bytes
        let newest = swapSamples.last!.bytes
        return newest > oldest ? newest - oldest : 0
    }

    private func compressedDelta() -> UInt64 {
        guard compressedSamples.count >= 2 else { return 0 }
        let oldest = compressedSamples.first!.bytes
        let newest = compressedSamples.last!.bytes
        return newest > oldest ? newest - oldest : 0
    }

    private func refreshSwapState() {
        let sd = swapDelta()
        let cd = compressedDelta()

        let MB: UInt64 = 1_048_576
        let GB: UInt64 = 1_073_741_824

        if sd >= GB {
            swapState = .swapCritical
        } else if sd >= 500 * MB {
            swapState = .swapSignificant
        } else if sd >= 100 * MB {
            swapState = .swapMinor
        } else if cd >= 300 * MB {
            swapState = .compressedGrowing
        } else {
            swapState = .normal
        }
    }

    private func buildNotificationBody(processes: [MenuBarProcess], urgent: Bool) -> String {
        let usedGB = Double(swapUsedBytes) / 1_073_741_824.0
        let usedStr = String(format: "%.1f GB", usedGB)
        let prefix = urgent
            ? "Swap has grown 1 GB+ in the last 5 minutes (\(usedStr) total). SSD write pressure is severe."
            : "Swap grew 500 MB+ in the last 5 minutes (\(usedStr) total). Performance is degrading."
        var body = prefix
        if let top = processes.max(by: { $0.memoryFootprintBytes < $1.memoryFootprintBytes }) {
            let topGB = Double(top.memoryFootprintBytes) / 1_073_741_824.0
            body += " Biggest contributor: \(top.name) (\(String(format: "%.1f GB", topGB)))."
        }
        return body
    }
}
