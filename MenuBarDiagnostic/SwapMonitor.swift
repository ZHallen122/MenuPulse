import Foundation
import Combine
import UserNotifications
import Darwin

enum SwapState: Equatable {
    case none
    case active
    case rapidGrowth
}

class SwapMonitor: ObservableObject {
    @Published var swapUsedBytes: UInt64 = 0 {
        didSet { refreshSwapState() }
    }
    @Published var swapTotalBytes: UInt64 = 0
    @Published var swapGrowthBytesPerSec: Double = 0 {
        didSet { refreshSwapState() }
    }
    @Published var swapState: SwapState = .none

    /// Closure that returns the current process list for notification body.
    var topProcessProvider: (() -> [MenuBarProcess])? = nil

    /// Exposed for unit tests to verify cooldown logic.
    var lastSwapNotificationDate: Date? = nil

    private var timer: DispatchSourceTimer?
    private var lastSwapUsedBytes: UInt64 = 0
    private var lastSampleTime: Date = .distantPast
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

    /// Returns the notification content. Exposed for unit tests.
    func buildNotificationContent(processes: [MenuBarProcess]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Your Mac is using disk as memory"
        content.body = buildNotificationBody(processes: processes)
        content.categoryIdentifier = "SWAP_ACTIVE"
        content.sound = .default
        return content
    }

    /// Returns true if the notification was enqueued (cooldown not active).
    /// Exposed for unit tests; does NOT actually post in XCTest environment.
    @discardableResult
    func checkAndMaybeNotify(processes: [MenuBarProcess]) -> Bool {
        if let last = lastSwapNotificationDate, Date().timeIntervalSince(last) < 3600 { return false }
        lastSwapNotificationDate = Date()

        // Skip actual delivery in XCTest environment.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            let content = buildNotificationContent(processes: processes)
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
        var swapInfo = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swapInfo, &size, nil, 0) != 0 {
            NSLog("SwapMonitor: sysctlbyname vm.swapusage failed (errno=%d)", errno)
            return
        }

        let now = Date()
        let used = swapInfo.xsu_used
        let total = swapInfo.xsu_total

        var growth: Double = 0
        if lastSampleTime != .distantPast {
            let elapsed = now.timeIntervalSince(lastSampleTime)
            if elapsed > 0 && used >= lastSwapUsedBytes {
                growth = Double(used - lastSwapUsedBytes) / elapsed
            }
        }

        let wasInactive = lastSwapUsedBytes == 0
        lastSwapUsedBytes = used
        lastSampleTime = now

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.swapUsedBytes = used
            self.swapTotalBytes = total
            self.swapGrowthBytesPerSec = growth

            // Notify on transition from inactive to active swap.
            if wasInactive && used > 0 {
                let processes = self.topProcessProvider?() ?? []
                self.checkAndMaybeNotify(processes: processes)
            }
        }
    }

    private func buildNotificationBody(processes: [MenuBarProcess]) -> String {
        let usedGB = Double(swapUsedBytes) / 1_073_741_824.0
        let usedStr = String(format: "%.1f GB", usedGB)
        var body = "Swap in use: \(usedStr). Performance is degrading and your SSD is absorbing write pressure."
        if let top = processes.max(by: { $0.memoryFootprintBytes < $1.memoryFootprintBytes }) {
            let topGB = Double(top.memoryFootprintBytes) / 1_073_741_824.0
            body += " Biggest contributor: \(top.name) (\(String(format: "%.1f GB", topGB)))."
        }
        return body
    }

    private func refreshSwapState() {
        if swapUsedBytes == 0 {
            swapState = .none
        } else if swapGrowthBytesPerSec > 167_000 {
            swapState = .rapidGrowth
        } else {
            swapState = .active
        }
    }
}
