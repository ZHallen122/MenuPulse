import XCTest

final class DataStoreBaselineTests: MenuBarDiagnosticTestCase {

    func testP90BaselineComputation() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // 10 processes with memory 10, 20, ..., 100 MB (different pids, same call)
        let processes = (1...10).map { i in
            makeProcess(bundleID: "com.test.P90", memoryMB: Double(i * 10), pid: Int32(i))
        }
        store.persistSamples(processes)
        Thread.sleep(forTimeInterval: 0.1)

        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        let baseline = store.baseline(for: "com.test.P90")
        XCTAssertNotNil(baseline, "baseline should exist after recomputeBaselines")
        // sorted [10,20,...,100]; p90Index = Int(9 * 0.9) = 8 → 90
        XCTAssertEqual(baseline!.p90MB, 90, accuracy: 0.01)
        // avg = (10+20+...+100)/10 = 55
        XCTAssertEqual(baseline!.avgMB, 55, accuracy: 0.01)
    }

    func testBaselineNilForUnknownBundleID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let baseline = store.baseline(for: "com.test.NeverSeen")
        XCTAssertNil(baseline, "baseline must be nil when no samples have been persisted for the bundle ID")
    }

    func testBaselineNilBeforeRecompute() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let processes = (1...10).map { i in
            makeProcess(bundleID: "com.test.BeforeRecompute", memoryMB: Double(i * 10), pid: Int32(i))
        }
        store.persistSamples(processes)
        Thread.sleep(forTimeInterval: 0.1)

        // No recomputeBaselines call — baseline must remain nil
        let baseline = store.baseline(for: "com.test.BeforeRecompute")
        XCTAssertNil(baseline, "baseline must be nil when samples exist but recomputeBaselines has not been called")
    }

    func testIsInPerAppLearningPeriodTrueAndFalse() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        store.resetToLearning(bundleID: "com.test.Learning", version: nil)
        Thread.sleep(forTimeInterval: 0.1)

        // Just started learning — elapsed ≈ 0 s < 4 h → true
        XCTAssertTrue(store.isInPerAppLearningPeriod(bundleID: "com.test.Learning", duration: 4 * 3600),
                      "isInPerAppLearningPeriod must be true when learning just started and duration is 4 hours")

        // Unknown bundleID has no DB entry; implementation defaults to true (unknown = in learning)
        XCTAssertTrue(store.isInPerAppLearningPeriod(bundleID: "com.test.Unknown", duration: 4 * 3600),
                      "isInPerAppLearningPeriod must be true for an unknown bundle ID (unknown defaults to learning)")

        // duration = 0 → elapsed > 0, so elapsed < 0 is false → returns false
        XCTAssertFalse(store.isInPerAppLearningPeriod(bundleID: "com.test.Learning", duration: 0),
                       "isInPerAppLearningPeriod must be false when duration window is 0 (already elapsed)")
    }

    func testPhase1Uses4xMedianThreshold() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Phase1Threshold"

        // 35 samples at 100 MB → sample_count = 35, median = 100 MB, phase_1 threshold = 400 MB
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 7100)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Trend samples for positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 7200)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 7201)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        let phases = [bundleID: "learning_phase_1"]

        // 350 MB < 4 × 100 MB = 400 MB → NOT anomalous
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 350)],
                          pressure: .warning, bundleIDPhases: phases)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "350 MB must NOT be anomalous under phase_1 threshold of 400 MB (4× median 100)")

        // 450 MB > 4 × 100 MB = 400 MB → IS anomalous
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 450)],
                          pressure: .warning, bundleIDPhases: phases)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "450 MB must be anomalous under phase_1 threshold of 400 MB (4× median 100)")
    }

    func testPhase2Uses3xMedianThreshold() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Phase2Threshold"

        // 35 samples at 100 MB → sample_count = 35, median = 100 MB, phase_2 threshold = 300 MB
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 7300)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Trend samples for positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 7400)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 7401)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        let phases = [bundleID: "learning_phase_2"]

        // 250 MB < 3 × 100 MB = 300 MB → NOT anomalous
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 250)],
                          pressure: .warning, bundleIDPhases: phases)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "250 MB must NOT be anomalous under phase_2 threshold of 300 MB (3× median 100)")

        // 350 MB > 3 × 100 MB = 300 MB → IS anomalous
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 350)],
                          pressure: .warning, bundleIDPhases: phases)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "350 MB must be anomalous under phase_2 threshold of 300 MB (3× median 100)")
    }

    func testPhase3Uses25xP90Threshold() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Phase3Threshold"

        // 35 samples at 100 MB → p90 = 100 MB, phase_3 threshold = 2.5 × 100 = 250 MB
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 7500)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Trend samples for positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 7600)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 7601)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        let phases = [bundleID: "learning_phase_3"]

        // 200 MB < 2.5 × p90(100) = 250 MB → NOT anomalous
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 200)],
                          pressure: .warning, bundleIDPhases: phases)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "200 MB must NOT be anomalous under phase_3 threshold of 250 MB (2.5× p90 100)")

        // 300 MB > 2.5 × p90(100) = 250 MB → IS anomalous
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning, bundleIDPhases: phases)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "300 MB must be anomalous under phase_3 threshold of 250 MB (2.5× p90 100)")
    }

    func test30SampleMinimumGuard() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.MinSamples"

        // 25 insertions → sample_count = 25, below 30-sample minimum
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 25, pidBase: 7700)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Trend samples for positive slope (also increment sample_count to 27)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 7800)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 7801)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 10× threshold — well above any phase threshold
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 1000)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "active"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.lastNotificationDates.isEmpty,
                      "no notification must fire when sample_count < 30, even when 10× above threshold")
    }

    func testPhase1NotificationCopyIsTentative() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Phase1Copy"

        // 35 samples → sample_count ≥ 30
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 7900)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Trend samples for positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 8000)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 8001)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 450 MB > 4 × median(100) = 400 MB threshold
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 450)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "learning_phase_1"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(detector.lastSentNotificationTitle,
                        "notification must have been sent for phase_1 above threshold with ≥30 samples")
        XCTAssertTrue(detector.lastSentNotificationTitle?.contains("still learning") == true,
                      "phase_1 notification title must contain 'still learning'")
    }

    func testActiveNotificationCopyIsAssertive() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.ActiveCopy"

        // 35 samples → sample_count ≥ 30, p90 ≈ 100 MB
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 8100)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Trend samples for positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 8200)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 8201)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 300 MB > 2.5 × p90(100) = 250 MB threshold (active, default sensitivity)
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "active"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(detector.lastSentNotificationTitle,
                        "notification must have been sent for active phase above threshold with ≥30 samples")
        XCTAssertTrue(detector.lastSentNotificationTitle?.contains("too much memory") == true,
                      "active-phase notification title must contain 'too much memory'")
    }

    func testStaleMarkingCoversLearningPhases() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.StalePhase1"
        let thirtyOneDaysAgo = Date().addingTimeInterval(-31 * 24 * 3600)

        // Insert a lifecycle row in learning_phase_1 with last_seen 31 days ago
        store.updateAppLifecycle(bundleID: bundleID,
                                 state: "learning_phase_1",
                                 version: nil,
                                 lastSeen: thirtyOneDaysAgo)
        Thread.sleep(forTimeInterval: 0.1)

        // Mark stale with a cutoff of 30 days ago
        let staleCutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        store.markStaleApps(lastSeenCutoff: staleCutoff)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(store.appState(for: bundleID), "stale",
                       "app in learning_phase_1 last seen 31 days ago must be marked stale")
    }

    func testStaleAppReappearsAfter31Days() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.StaleReturn"
        let now = Date()
        let thirtyOneDaysAgo = now.addingTimeInterval(-31 * 24 * 3600)

        // Seed an active entry last seen 31 days ago.
        store.updateAppLifecycle(bundleID: bundleID,
                                 state: "active",
                                 version: nil,
                                 lastSeen: thirtyOneDaysAgo)
        Thread.sleep(forTimeInterval: 0.1)

        // Mark apps stale using a 30-day cutoff — this entry should be caught.
        let staleCutoff = now.addingTimeInterval(-30 * 24 * 3600)
        store.markStaleApps(lastSeenCutoff: staleCutoff)
        Thread.sleep(forTimeInterval: 0.1)

        // Confirm DB correctly wrote "stale".
        XCTAssertEqual(store.lifecycleEntry(for: bundleID)?.state, "stale",
                       "app last seen 31 days ago should be marked stale in the DB")

        // Simulate ProcessMonitor missing the cache (entry evicted) and hitting the DB:
        // it reads "stale", then calls resetToLearning.
        store.resetToLearning(bundleID: bundleID, version: nil)
        Thread.sleep(forTimeInterval: 0.1)

        // After resetToLearning the app should be back in learning_phase_1.
        XCTAssertEqual(store.lifecycleEntry(for: bundleID)?.state, "learning_phase_1",
                       "app returning after stale period should restart in learning_phase_1")
    }
}
