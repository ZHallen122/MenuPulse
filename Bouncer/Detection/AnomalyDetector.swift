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
///
/// Anomaly thresholds are gated by a four-phase lifecycle:
///   `learning_phase_1` → `learning_phase_2` → `learning_phase_3` → `active`
/// Earlier phases use looser median-based thresholds to reduce false positives on
/// newly-seen apps (whose p90 baseline is not yet statistically reliable). Only the
/// `active` phase applies the p90 baseline with the full user-configured sensitivity
/// multiplier.
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

    /// Active alert_events row IDs, keyed by bundle ID.
    /// An entry exists while the anomaly is confirmed and open in the DB.
    // internal (not private) so tests can verify event lifecycle
    var activeAlertEventIDs: [String: Int64] = [:]

    /// Whether swap was actively growing during the current evaluate() call.
    /// Set by ProcessMonitor / AppDelegate before calling evaluate().
    var swapCurrentlyActive: Bool = false

    init(dataStore: DataStore, prefs: PreferencesManager) {
        self.dataStore = dataStore
        self.prefs = prefs
        super.init()
        // UNUserNotificationCenter requires a proper app bundle; skip in test runners.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// internal: populated by sendNotification before the UNUserNotificationCenter guard;
    /// lets unit tests verify notification copy without requiring a full app bundle.
    var lastSentNotificationTitle: String?
    var lastSentNotificationBody: String?

    /// Evaluate all running processes against the three anomaly conditions.
    /// Called from ProcessMonitor after each DataStore persist tick.
    /// Per-app lifecycle phase in `bundleIDPhases` controls baseline metric and threshold.
    func evaluate(processes: [MenuBarProcess], pressure: MemoryPressure,
                  bundleIDPhases: [String: String] = [:]) {
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
        let now = Date()
        // In testing mode: samples persist every 5 s, so use a 2-minute window to
        // accumulate enough data points for a meaningful trend (normally 30 min).
        let trendingWindow: TimeInterval = testing ? -2 * 60 : -30 * 60
        let thirtyMinutesAgo = now.addingTimeInterval(trendingWindow)

        var liveBundleIDs = Set<String>()
        var currentlyAnomalous = Set<String>()
        let sensitivityMultiplier = prefs.sensitivity.anomalyMultiplier

        for process in processes {
            autoreleasepool {
                guard let bundleID = process.bundleIdentifier else { return }
                liveBundleIDs.insert(bundleID)

                let state = bundleIDPhases[bundleID] ?? "learning_phase_1"

                // Skip ignored apps.
                guard state != "ignored", !ignoredIDs.contains(bundleID) else { return }

                // Select baseline metric and multiplier based on lifecycle phase.
                let useMedian: Bool
                let phaseMultiplier: Double
                switch state {
                case "learning_phase_1": useMedian = true;  phaseMultiplier = 4.0
                case "learning_phase_2": useMedian = true;  phaseMultiplier = 3.0
                case "learning_phase_3": useMedian = false; phaseMultiplier = 2.5
                default:                 useMedian = false; phaseMultiplier = sensitivityMultiplier
                }

                // 30-sample minimum: icon can tint but notification is suppressed below this.
                let sampleCount = dataStore.sampleCount(for: bundleID)
                let hasEnoughSamples = sampleCount >= 30

                // Condition 1: current memory > phase baseline × phase multiplier
                guard let baseline = dataStore.baseline(for: bundleID) else { return }
                let baselineValue = useMedian ? baseline.medianMB : baseline.p90MB
                guard baselineValue > 0 else { return }

                let currentMB = Double(process.memoryFootprintBytes) / 1_048_576.0
                guard currentMB > baselineValue * phaseMultiplier else {
                    anomalyStartDates.removeValue(forKey: bundleID)
                    return
                }

                // Condition 2: memory trending upward over the last 30 minutes
                let samples = dataStore.recentSamples(for: bundleID, since: thirtyMinutesAgo)
                guard samples.count >= 2, linearRegressionSlope(samples) > 0 else {
                    anomalyStartDates.removeValue(forKey: bundleID)
                    return
                }

                // All 3 conditions met — mark as anomalous for the view layer
                currentlyAnomalous.insert(bundleID)

                // Record when anomaly started
                if anomalyStartDates[bundleID] == nil {
                    anomalyStartDates[bundleID] = now
                }
                guard let anomalyStart = anomalyStartDates[bundleID] else { return }

                // Must be anomalous for 10 consecutive minutes (or 10 s in testing mode).
                let anomalyDurationGate: TimeInterval = testing ? 10 : 10 * 60
                guard now.timeIntervalSince(anomalyStart) >= anomalyDurationGate else { return }

                // Must have at least 30 samples for a reliable baseline before notifying.
                guard hasEnoughSamples else { return }

                // --- Alert event tracking (History view) ---
                // Open a new event row when the anomaly is first confirmed.
                if activeAlertEventIDs[bundleID] == nil {
                    let eventID = dataStore.insertAlertEvent(
                        bundleID: bundleID,
                        appName: process.name,
                        startedAt: anomalyStart,
                        peakMemoryMB: currentMB,
                        swapCorrelated: swapCurrentlyActive
                    )
                    if eventID >= 0 {
                        activeAlertEventIDs[bundleID] = eventID
                    }
                } else if let eventID = activeAlertEventIDs[bundleID] {
                    // Update the running peak memory while the anomaly persists.
                    dataStore.updateAlertEventPeak(id: eventID, peakMemoryMB: currentMB)
                }

                // 24-hour per-app notification cooldown
                if let lastSent = lastNotificationDates[bundleID],
                   now.timeIntervalSince(lastSent) < 24 * 3600 { return }

                let ratio = currentMB / baselineValue
                sendNotification(bundleID: bundleID, appName: process.name, currentMB: currentMB, ratio: ratio, phase: state)
                lastNotificationDates[bundleID] = now
            }
        }

        // Clear anomaly tracking for processes that are no longer running
        for key in anomalyStartDates.keys where !liveBundleIDs.contains(key) {
            anomalyStartDates.removeValue(forKey: key)
        }

        // Close open alert events for anomalies that have resolved.
        let resolvedBundleIDs = Set(activeAlertEventIDs.keys).subtracting(currentlyAnomalous)
        for bundleID in resolvedBundleIDs {
            if let eventID = activeAlertEventIDs.removeValue(forKey: bundleID) {
                dataStore.closeAlertEvent(id: eventID, endedAt: now, userAction: "none")
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.anomalousBundleIDs != currentlyAnomalous {
                self.anomalousBundleIDs = currentlyAnomalous
            }
        }
    }


    // MARK: - Notifications

    /// Records that the user manually quit or restarted `bundleID` from the popover.
    /// Call this before the actual terminate() so the event is closed with the right action.
    func recordUserAction(_ action: String, for bundleID: String) {
        guard action == "quit" || action == "restarted" else { return }
        if let eventID = activeAlertEventIDs.removeValue(forKey: bundleID) {
            dataStore.closeAlertEvent(id: eventID, endedAt: Date(), userAction: action)
        }
    }

    /// Fires a synthetic "Safari is using too much memory" notification so you can
    /// verify the full notification→action flow without waiting for real anomaly conditions.
    /// Only works when testingMode is enabled.
    func fireTestAlert() {
        guard prefs.testingMode else { return }
        sendNotification(
            bundleID: "com.apple.Safari",
            appName: "Safari [TEST]",
            currentMB: 1234,
            ratio: 3.7,
            phase: "active"
        )
    }

    func sendNotification(bundleID: String, appName: String, currentMB: Double, ratio: Double, phase: String) {
        let content = UNMutableNotificationContent()

        // Phase-aware notification copy.
        let memStr: String = currentMB >= 1000
            ? String(format: "%.1f GB", currentMB / 1024.0)
            : String(format: "%.0f MB", currentMB)

        if phase == "learning_phase_1" || phase == "learning_phase_2" {
            content.title = "Bouncer is still learning \(appName)"
            content.body = "\(appName)'s memory looks unusually high (\(memStr)). Restarting it may help if your Mac feels slow."
        } else {
            content.title = "\(appName) is using too much memory"
            content.body = String(format: "Using %@ — %.1fx its normal level. Restart \(appName) to free up memory.", memStr, ratio)
        }

        content.sound = .default
        content.categoryIdentifier = "MEMORY_ANOMALY"
        content.userInfo = ["bundleID": bundleID, "appName": appName]

        // Capture for unit-test verification before the XCTest guard exits.
        lastSentNotificationTitle = content.title
        lastSentNotificationBody = content.body

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
            // Record user action before closing; restartApp runs asynchronously.
            if let eventID = activeAlertEventIDs.removeValue(forKey: bundleID) {
                dataStore.closeAlertEvent(id: eventID, endedAt: Date(), userAction: "restarted")
            }
            restartApp(bundleID: bundleID, appName: appName)
        case "IGNORE":
            if let eventID = activeAlertEventIDs.removeValue(forKey: bundleID) {
                dataStore.closeAlertEvent(id: eventID, endedAt: Date(), userAction: "ignored")
            }
            DispatchQueue.main.async {
                if !bundleID.isEmpty && !self.prefs.ignoredBundleIDs.contains(bundleID) {
                    self.prefs.ignoredBundleIDs.append(bundleID)
                }
            }
            // Mirror the ignore into app_lifecycle so the state machine stays consistent.
            // This prevents lifecycle transitions (version change, stale return) from
            // accidentally resetting an ignored app back to "learning".
            if !bundleID.isEmpty {
                dataStore.markIgnored(bundleID: bundleID)
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
            guard let url = appURL else {
                NSLog("AnomalyDetector: appURL is nil for %@ (%@); skipping relaunch", appName, bundleID)
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error {
                    NSLog("AnomalyDetector: failed to relaunch %@ (%@): %@", appName, bundleID, error.localizedDescription)
                }
            }
        }
    }
}
