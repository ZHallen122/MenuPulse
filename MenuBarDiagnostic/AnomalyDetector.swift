import AppKit
import UserNotifications

/// Detects per-process memory anomalies using three-condition logic and sends
/// UNUserNotification alerts with Restart Now / Ignore action buttons.
///
/// All three conditions must hold simultaneously to flag an app:
///   1. Current memory > p90 baseline × sensitivity anomaly multiplier
///   2. Memory has been increasing for 30+ minutes (linear regression slope > 0)
///   3. System memory pressure is .warning or .critical
///
/// A notification is sent only when the app has been anomalous for 10+ consecutive
/// minutes AND no notification has been sent for that app in the past 24 hours.
final class AnomalyDetector: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    private let dataStore: DataStore
    private let prefs: PreferencesManager

    /// Bundle IDs where all 3 anomaly conditions are currently met.
    /// Updated every evaluate() call; drives orange icon tint and highlighting in StatusMenuView.
    @Published var anomalousBundleIDs: Set<String> = []

    /// Tracks when each bundle ID first entered an anomalous state (all 3 conditions met).
    // internal (not private) so tests can pre-seed
    var anomalyStartDates: [String: Date] = [:]

    /// Tracks when the last notification was sent per bundle ID (24 h cooldown).
    // internal (not private) so tests can pre-seed
    var lastNotificationDates: [String: Date] = [:]

    init(dataStore: DataStore, prefs: PreferencesManager) {
        self.dataStore = dataStore
        self.prefs = prefs
        super.init()
        // UNUserNotificationCenter requires a proper app bundle; skip in test runners.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Evaluate all running processes against the three anomaly conditions.
    /// Called from ProcessMonitor after each DataStore persist tick.
    /// Apps in `learningBundleIDs` are skipped — their baseline is still forming.
    func evaluate(processes: [MenuBarProcess], pressure: MemoryPressure,
                  learningBundleIDs: Set<String> = []) {
        // Suppress all anomaly detection and notifications during the 3-day learning period.
        guard !prefs.isInLearningPeriod else {
            anomalyStartDates.removeAll()
            DispatchQueue.main.async { self.anomalousBundleIDs = [] }
            return
        }

        let testing = prefs.testingMode

        // Condition 3: system memory pressure must be .warning or .critical.
        // Bypassed in testing mode so you don't need to simulate system pressure.
        if !testing {
            guard pressure == .warning || pressure == .critical else {
                anomalyStartDates.removeAll()
                DispatchQueue.main.async { self.anomalousBundleIDs = [] }
                return
            }
        }

        let ignoredIDs = Set(prefs.ignoredBundleIDs)
        let multiplier = prefs.sensitivity.anomalyMultiplier
        let now = Date()
        // In testing mode: samples persist every 5 s, so use a 2-minute window to
        // accumulate enough data points for a meaningful trend (normally 30 min).
        let trendingWindow: TimeInterval = testing ? -2 * 60 : -30 * 60
        let thirtyMinutesAgo = now.addingTimeInterval(trendingWindow)

        var liveBundleIDs = Set<String>()
        var currentlyAnomalous = Set<String>()

        for process in processes {
            guard let bundleID = process.bundleIdentifier,
                  !ignoredIDs.contains(bundleID),
                  !learningBundleIDs.contains(bundleID) else { continue }

            liveBundleIDs.insert(bundleID)

            // Condition 1: current memory > p90 baseline × anomaly multiplier
            guard let baseline = dataStore.baseline(for: bundleID),
                  baseline.p90MB > 0 else { continue }

            let currentMB = Double(process.memoryFootprintBytes) / 1_048_576.0
            guard currentMB > baseline.p90MB * multiplier else {
                anomalyStartDates.removeValue(forKey: bundleID)
                continue
            }

            // Condition 2: memory trending upward over the last 30 minutes
            let samples = dataStore.recentSamples(for: bundleID, since: thirtyMinutesAgo)
            guard samples.count >= 2, linearRegressionSlope(samples) > 0 else {
                anomalyStartDates.removeValue(forKey: bundleID)
                continue
            }

            // All 3 conditions met — mark as anomalous for the view layer
            currentlyAnomalous.insert(bundleID)

            // Record when anomaly started
            if anomalyStartDates[bundleID] == nil {
                anomalyStartDates[bundleID] = now
            }
            guard let anomalyStart = anomalyStartDates[bundleID] else { continue }

            // Must be anomalous for 10 consecutive minutes (or 10 s in testing mode).
            let anomalyDurationGate: TimeInterval = testing ? 10 : 10 * 60
            guard now.timeIntervalSince(anomalyStart) >= anomalyDurationGate else { continue }

            // 24-hour per-app notification cooldown
            if let lastSent = lastNotificationDates[bundleID],
               now.timeIntervalSince(lastSent) < 24 * 3600 { continue }

            let ratio = currentMB / baseline.p90MB
            sendNotification(bundleID: bundleID, appName: process.name, currentMB: currentMB, ratio: ratio)
            lastNotificationDates[bundleID] = now
        }

        // Clear anomaly tracking for processes that are no longer running
        for key in anomalyStartDates.keys where !liveBundleIDs.contains(key) {
            anomalyStartDates.removeValue(forKey: key)
        }

        DispatchQueue.main.async {
            self.anomalousBundleIDs = currentlyAnomalous
        }
    }

    // MARK: - Linear Regression

    /// Computes the linear regression slope over the sample set.
    /// x = elapsed seconds from the first sample, y = memoryMB.
    /// A positive slope indicates memory is trending upward.
    func linearRegressionSlope(_ samples: [(memoryMB: Double, timestamp: Date)]) -> Double {
        guard let first = samples.first else { return 0 }
        let n = Double(samples.count)

        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0

        for s in samples {
            let x = s.timestamp.timeIntervalSince(first.timestamp)
            let y = s.memoryMB
            sumX  += x
            sumY  += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return 0 }
        return (n * sumXY - sumX * sumY) / denominator
    }

    // MARK: - Notifications

    /// Fires a synthetic "Safari is using too much memory" notification so you can
    /// verify the full notification→action flow without waiting for real anomaly conditions.
    /// Only works when testingMode is enabled.
    func fireTestAlert() {
        guard prefs.testingMode else { return }
        sendNotification(
            bundleID: "com.apple.Safari",
            appName: "Safari [TEST]",
            currentMB: 1234,
            ratio: 3.7
        )
    }

    func sendNotification(bundleID: String, appName: String, currentMB: Double, ratio: Double) {
        let content = UNMutableNotificationContent()
        content.title = "\(appName) is using too much memory"
        if currentMB >= 1000 {
            let gb = currentMB / 1024.0
            content.body = String(format: "Using %.1f GB — %.1fx its normal level. System memory pressure is elevated.", gb, ratio)
        } else {
            content.body = String(format: "Using %.0f MB — %.1fx its normal level. System memory pressure is elevated.", currentMB, ratio)
        }
        content.sound = .default
        content.categoryIdentifier = "MEMORY_ANOMALY"
        content.userInfo = ["bundleID": bundleID, "appName": appName]

        let request = UNNotificationRequest(
            identifier: "anomaly.\(bundleID)",
            content: content,
            trigger: nil
        )
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("AnomalyDetector: failed to schedule notification for %@: %@", bundleID, error.localizedDescription)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let bundleID = userInfo["bundleID"] as? String ?? ""
        let appName  = userInfo["appName"]  as? String ?? ""

        switch response.actionIdentifier {
        case "RESTART_NOW":
            restartApp(bundleID: bundleID, appName: appName)
        case "IGNORE":
            DispatchQueue.main.async {
                if !bundleID.isEmpty && !self.prefs.ignoredBundleIDs.contains(bundleID) {
                    self.prefs.ignoredBundleIDs.append(bundleID)
                }
            }
        default:
            break // default dismissal — do nothing
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Restart

    private func restartApp(bundleID: String, appName: String) {
        let workspace = NSWorkspace.shared
        guard let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }

        // Pre-compute the app URL before terminating so we don't need to capture workspace.
        let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID)
        let terminated = app.terminate()
        guard terminated else {
            NSLog("AnomalyDetector: terminate() returned false for %@ (%@); skipping relaunch", appName, bundleID)
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard let url = appURL else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error {
                    NSLog("AnomalyDetector: failed to relaunch %@ (%@): %@", appName, bundleID, error.localizedDescription)
                }
            }
        }
    }
}
