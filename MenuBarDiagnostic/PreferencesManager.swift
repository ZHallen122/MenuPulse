import Foundation
import SwiftUI

class PreferencesManager: ObservableObject {
    @AppStorage("refreshInterval") var refreshInterval: Double = 2.0
    @AppStorage("cpuAlertThreshold") var cpuAlertThreshold: Double = 0.05
    @AppStorage("ramAlertThresholdMB") var ramAlertThresholdMB: Double = 200.0
}
