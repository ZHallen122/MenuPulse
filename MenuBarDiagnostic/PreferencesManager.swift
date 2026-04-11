import Foundation
import SwiftUI

/// How aggressively alert thresholds are applied.
///
/// Multiplied against the base CPU and RAM thresholds in `PreferencesManager`:
/// - `.conservative` doubles them (fewer alerts)
/// - `.default_` leaves them unchanged
/// - `.aggressive` halves them (more alerts)
enum Sensitivity: String, CaseIterable {
    case conservative
    case `default_` = "default"
    case aggressive

    var label: String {
        switch self {
        case .conservative: return "Conservative"
        case .default_:     return "Default"
        case .aggressive:   return "Aggressive"
        }
    }

    /// Multiplier applied to CPU and RAM alert thresholds.
    var thresholdMultiplier: Double {
        switch self {
        case .conservative: return 2.0
        case .default_:     return 1.0
        case .aggressive:   return 0.5
        }
    }

    /// Multiplier applied to the p90 baseline to determine anomaly threshold.
    var anomalyMultiplier: Double {
        switch self {
        case .conservative: return 4.0
        case .default_:     return 2.5
        case .aggressive:   return 1.5
        }
    }
}

class PreferencesManager: ObservableObject {
    @AppStorage("refreshInterval")    var refreshInterval:    Double = 2.0
    @AppStorage("cpuAlertThreshold")  var cpuAlertThreshold:  Double = 0.05
    @AppStorage("ramAlertThresholdMB") var ramAlertThresholdMB: Double = 200.0

    /// Sensitivity level stored as its raw String value.
    @AppStorage("sensitivity") var sensitivity: Sensitivity = .default_

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("showMemoryPressureInMenuBar") var showMemoryPressureInMenuBar: Bool = false

    /// Bundle IDs to exclude from scanning, stored as a comma-joined string.
    @AppStorage("ignoredBundleIDsRaw") var ignoredBundleIDsRaw: String = ""

    /// Date the app was first launched, persisted in UserDefaults.
    /// Uses UserDefaults.standard directly (not @AppStorage) so it is readable
    /// from non-SwiftUI code (e.g. AnomalyDetector).
    var firstLaunchDate: Date {
        if let d = UserDefaults.standard.object(forKey: "firstLaunchDate") as? Date { return d }
        let now = Date()
        UserDefaults.standard.set(now, forKey: "firstLaunchDate")
        return now
    }

    /// True during the 3-day baseline learning period after first launch.
    /// Always returns false when testingMode is enabled.
    var isInLearningPeriod: Bool {
        guard !testingMode else { return false }
        return Date().timeIntervalSince(firstLaunchDate) < 3 * 86400
    }

    /// When true, bypasses the learning period, memory pressure guard, and collapses
    /// the 30-min trending window / 10-min anomaly-duration gate to 30 s / 10 s so
    /// anomaly detection can be exercised without waiting.
    @AppStorage("testingMode") var testingMode: Bool = false

    /// Parsed list of ignored bundle identifiers.
    var ignoredBundleIDs: [String] {
        get {
            ignoredBundleIDsRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            ignoredBundleIDsRaw = newValue.joined(separator: ",")
        }
    }
}
