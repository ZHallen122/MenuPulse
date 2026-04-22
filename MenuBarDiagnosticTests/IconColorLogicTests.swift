import XCTest
import AppKit

final class IconColorLogicTests: MenuBarDiagnosticTestCase {

    // (1) Anomaly alert sets orange icon state
    func testIconColorOrangeWhenPendingAnomalyAlert() {
        // swapState = .normal, pendingAnomalyAlert = true → orange
        let color = iconColor(swapState: .normal, pendingAnomalyAlert: true)
        XCTAssertEqual(color, .systemOrange,
                       "icon color must be orange when swap is idle but a pending anomaly alert exists")
    }

    // (2) Popover open clears alert state — icon returns to green
    func testIconColorGreenAfterAlertCleared() {
        // Simulate the state after togglePopover sets pendingAnomalyAlert = false
        let color = iconColor(swapState: .normal, pendingAnomalyAlert: false)
        XCTAssertEqual(color, .systemGreen,
                       "icon color must be green when swap is idle and no pending alert (simulates post-popover-open state)")
    }

    // (3) Alert resolves when anomaly detector goes empty
    func testIconColorGreenWhenAnomalyDetectorGoesEmpty() {
        // When anomalousBundleIDs transitions to empty, the Combine sink sets pendingAnomalyAlert = false.
        // Verify that iconColor() returns green under those conditions.
        let detector = AnomalyDetector(dataStore: DataStore(path: ":memory:"), prefs: PreferencesManager())

        // Detector starts empty; evaluating with no processes confirms no anomaly is introduced.
        // Verifies that iconColor() returns green when anomalousBundleIDs is empty.
        detector.evaluate(processes: [], pressure: .normal)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.isEmpty,
                      "evaluating with empty processes + normal pressure must yield no anomalies")

        // The Combine sink in AppDelegate mirrors anomalousBundleIDs.isEmpty → pendingAnomalyAlert = false.
        let pendingAfterClear = !detector.anomalousBundleIDs.isEmpty
        let color = iconColor(swapState: .normal, pendingAnomalyAlert: pendingAfterClear)
        XCTAssertEqual(color, .systemGreen,
                       "icon color must be green once anomaly detector is empty and pendingAnomalyAlert is cleared")
    }

    // (4) Multiple concurrent anomalies — any anomaly triggers orange
    func testIconColorOrangeWithMultipleConcurrentAnomalies() {
        // When anomalousBundleIDs is non-empty (regardless of count), pendingAnomalyAlert becomes true.
        // Verify iconColor reports orange for swapState = .none + pendingAlert = true.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleA = "com.test.Concurrent.A"
        let bundleB = "com.test.Concurrent.B"

        // Build baselines for both apps: p90 = 50 MB → threshold = 125 MB
        let baseProcsA = (1...10).map { i in makeProcess(bundleID: bundleA, memoryMB: 50, pid: Int32(2000 + i)) }
        let baseProcsB = (1...10).map { i in makeProcess(bundleID: bundleB, memoryMB: 50, pid: Int32(2100 + i)) }
        store.persistSamples(baseProcsA + baseProcsB)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Positive trend for both apps
        store.persistSamples([
            makeProcess(bundleID: bundleA, memoryMB: 100, pid: 2200),
            makeProcess(bundleID: bundleB, memoryMB: 100, pid: 2201)
        ])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([
            makeProcess(bundleID: bundleA, memoryMB: 200, pid: 2202),
            makeProcess(bundleID: bundleB, memoryMB: 200, pid: 2203)
        ])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleA] = Date().addingTimeInterval(-11 * 60)
        detector.anomalyStartDates[bundleB] = Date().addingTimeInterval(-11 * 60)

        detector.evaluate(processes: [
            makeProcess(bundleID: bundleA, memoryMB: 300),
            makeProcess(bundleID: bundleB, memoryMB: 300)
        ], pressure: .warning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Both apps should be anomalous
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleA), "bundleA must be anomalous")
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleB), "bundleB must be anomalous")
        XCTAssertGreaterThanOrEqual(detector.anomalousBundleIDs.count, 2,
                                    "both concurrent anomalies must appear in anomalousBundleIDs")

        // With ≥1 anomaly, pendingAnomalyAlert becomes true → icon must be orange
        let pendingAlert = !detector.anomalousBundleIDs.isEmpty
        let color = iconColor(swapState: .normal, pendingAnomalyAlert: pendingAlert)
        XCTAssertEqual(color, .systemOrange,
                       "icon must be orange when multiple concurrent anomalies are present")
    }

    // (5a) Edge case: swapCritical overrides pending alert → red, not orange
    func testIconColorRedWhenSwapCriticalOverridesPendingAlert() {
        let color = iconColor(swapState: .swapCritical, pendingAnomalyAlert: true)
        XCTAssertEqual(color, .systemRed,
                       "swapCritical must take highest priority — icon must be red even with a pending alert")
    }

    // (5b) Edge case: swapSignificant → orange regardless of pending alert
    func testIconColorOrangeWhenSwapSignificantNoPendingAlert() {
        let color = iconColor(swapState: .swapSignificant, pendingAnomalyAlert: false)
        XCTAssertEqual(color, .systemOrange,
                       "icon must be orange when swapSignificant, regardless of pending alert state")
    }

    // (5b2) Edge case: swapMinor → yellow
    func testIconColorYellowWhenSwapMinor() {
        let color = iconColor(swapState: .swapMinor, pendingAnomalyAlert: false)
        XCTAssertEqual(color, .systemYellow, "icon must be yellow for swapMinor")
    }

    // (5b3) Edge case: compressedGrowing → yellow
    func testIconColorYellowWhenCompressedGrowing() {
        let color = iconColor(swapState: .compressedGrowing, pendingAnomalyAlert: false)
        XCTAssertEqual(color, .systemYellow, "icon must be yellow for compressedGrowing")
    }

    // (5c) Edge case: no baseline → evaluate produces no anomaly → icon green
    func testIconColorGreenWhenNoBaselineForProcess() {
        // Without a baseline, condition 1 cannot be satisfied → no anomaly flagged
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.evaluate(processes: [makeProcess(bundleID: "com.test.NoBaseline", memoryMB: 9999)],
                          pressure: .critical)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(detector.anomalousBundleIDs.isEmpty,
                      "process with no baseline must not be flagged as anomalous")

        let pendingAlert = !detector.anomalousBundleIDs.isEmpty
        let color = iconColor(swapState: .normal, pendingAnomalyAlert: pendingAlert)
        XCTAssertEqual(color, .systemGreen,
                       "icon must be green when no anomaly is detected due to missing baseline")
    }
}
