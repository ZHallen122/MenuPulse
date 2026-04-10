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
}

class PreferencesManager: ObservableObject {
    @AppStorage("refreshInterval")    var refreshInterval:    Double = 2.0
    @AppStorage("cpuAlertThreshold")  var cpuAlertThreshold:  Double = 0.05
    @AppStorage("ramAlertThresholdMB") var ramAlertThresholdMB: Double = 200.0

    /// Sensitivity level stored as its raw String value.
    @AppStorage("sensitivity") var sensitivity: Sensitivity = .default_

    /// Bundle IDs to exclude from scanning, stored as a comma-joined string.
    @AppStorage("ignoredBundleIDsRaw") var ignoredBundleIDsRaw: String = ""

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
