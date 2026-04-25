import XCTest

final class AnomalyDetectorTests: BouncerTestCase {

    func testSlopePositiveForIncreasingMemory() {
        let now = Date()
        let samples: [(memoryMB: Double, timestamp: Date)] = [
            (100, now),
            (150, now.addingTimeInterval(600)),
            (200, now.addingTimeInterval(1200))
        ]
        XCTAssertGreaterThan(linearRegressionSlope(samples), 0)
    }

    func testSlopeNegativeForDecreasingMemory() {
        let now = Date()
        let samples: [(memoryMB: Double, timestamp: Date)] = [
            (200, now),
            (150, now.addingTimeInterval(600)),
            (100, now.addingTimeInterval(1200))
        ]
        XCTAssertLessThan(linearRegressionSlope(samples), 0)
    }

    func testSlopeZeroForFlatMemory() {
        let now = Date()
        let samples: [(memoryMB: Double, timestamp: Date)] = [
            (100, now),
            (100, now.addingTimeInterval(600)),
            (100, now.addingTimeInterval(1200))
        ]
        XCTAssertEqual(linearRegressionSlope(samples), 0, accuracy: 0.0001)
    }

    func testLinearRegressionSlopeSingleSample() {
        let result = linearRegressionSlope([(memoryMB: 100, timestamp: Date())])
        XCTAssertEqual(result, 0.0, "linearRegressionSlope must return 0.0 for a single-sample array (denominator guard path)")
    }

    func testNormalPressureClearsAnomalies() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.evaluate(processes: [makeProcess(bundleID: "com.test.C3", memoryMB: 999)],
                          pressure: .normal)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.isEmpty,
                      "normal pressure must yield no anomalies (condition 3 fails)")
    }

    func testMemoryBelowThresholdNotAnomalous() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // Baseline p90 = 200 MB; default multiplier 2.5 → threshold 500 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: "com.test.C1", memoryMB: 200, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // 300 MB < 500 MB threshold → condition 1 fails
        detector.evaluate(processes: [makeProcess(bundleID: "com.test.C1", memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains("com.test.C1"),
                       "memory below threshold must not be anomalous (condition 1 fails)")
    }

    func testSameSampleTimestampNotAnomalous() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // Baseline p90 = 50 MB → threshold 125 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: "com.test.C2", memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // 300 MB > 125 MB (condition 1 ✓), pressure warning (condition 3 ✓)
        // But all inserted samples share the same second-level timestamp
        // → slope denominator = 0 → linearRegressionSlope returns 0 → condition 2 fails
        detector.evaluate(processes: [makeProcess(bundleID: "com.test.C2", memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains("com.test.C2"),
                       "zero/flat slope must not satisfy condition 2")
    }

    func testAllConditionsMetMarksAnomalous() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.AllConds"
        // Baseline p90 = 50 MB → threshold 125 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 100)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 101)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Pre-seed anomalyStartDates to satisfy the 10-min persistence check
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 300 MB > 125 MB ✓; positive slope ✓; pressure .warning ✓
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "all 3 conditions met must mark process as anomalous")
    }

    func testAnomalyStartDateSetOnFirstDetection() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.StartDate"
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 200)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 201)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        XCTAssertNil(detector.anomalyStartDates[bundleID], "anomalyStartDates must be empty before first evaluate")

        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(detector.anomalyStartDates[bundleID],
                        "anomalyStartDates must be set after first detection (10-min timer starts)")
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID))
    }

    func test24HourCooldownPreventsRenotification() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Cooldown"
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 300)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 301)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Simulate a notification sent 1 hour ago (within 24-h window)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        detector.lastNotificationDates[bundleID] = oneHourAgo
        // Satisfy 10-min persistence check
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Notification date must NOT be refreshed during the 24-h cooldown window
        XCTAssertEqual(
            detector.lastNotificationDates[bundleID]?.timeIntervalSince1970 ?? 0,
            oneHourAgo.timeIntervalSince1970,
            accuracy: 1.0,
            "lastNotificationDates must not be updated within 24-h cooldown"
        )
        // The process is still flagged in the view layer regardless of cooldown
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID))
    }

    func testPhase1Under30SamplesNoNotification() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Phase1Under30"

        // 3 calls to persistSamples at 100 MB → sample_count = 3, median = 100 MB
        for i in 0..<3 {
            store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: Int32(6000 + i))])
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1s apart → positive slope (sample_count → 5, still below 30)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 6100)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 6101)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Pre-seed anomalyStartDate to satisfy 10-min persistence gate
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 450 MB > median(100) × 4.0 = 400 MB (condition 1 ✓); positive slope (condition 2 ✓); .warning (condition 3 ✓)
        // sample_count = 5 < 30 → notification suppressed, but icon tint must fire
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 450)],
                          pressure: .warning,
                          bundleIDPhases: [bundleID: "learning_phase_1"])

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "phase_1 app must appear in anomalousBundleIDs for icon tinting even with < 30 samples")
        XCTAssertNil(detector.lastNotificationDates[bundleID],
                     "notification must be suppressed when sample_count < 30")
    }

    func testIgnoredBundleIDIsNotFlagged() {
        // Not in learning period
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")

        let bundleID = "com.test.Ignored"
        let prefs = PreferencesManager()
        prefs.ignoredBundleIDsRaw = bundleID

        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: prefs)
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "ignored bundle ID must never be flagged as anomalous")
    }

    func testDepartedProcessClearsAnomalyStartDate() {
        // Not in learning period
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")

        // DataStore with no baseline for "com.test.Other"
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Pre-seed departed process
        detector.anomalyStartDates["com.test.Departed"] = Date()

        // Evaluate with a different process that has no baseline — it enters liveBundleIDs
        // but skips anomaly logic. The cleanup loop then removes "com.test.Departed".
        detector.evaluate(processes: [makeProcess(bundleID: "com.test.Other", memoryMB: 100)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(detector.anomalyStartDates["com.test.Departed"],
                     "anomalyStartDate must be cleared for a process no longer in the process list")
    }

    func testConservativeSensitivityRequiresHigherThreshold() {
        UserDefaults.standard.set("conservative", forKey: "sensitivity")
        defer { UserDefaults.standard.removeObject(forKey: "sensitivity") }

        // Not in learning period
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")

        let bundleID = "com.test.Conservative"
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // Baseline p90 = 100 MB → conservative threshold = 100 × 4.0 = 400 MB (active + conservative)
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 100, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 500)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 501)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 350 MB is above default threshold (100 × 2.5 = 250 MB) but below conservative (400 MB)
        // Explicitly set phase to "active" so sensitivity multiplier applies.
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 350)],
                          pressure: .warning,
                          bundleIDPhases: [bundleID: "active"])

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "350 MB must not trigger conservative threshold of 400 MB (p90 × 4.0)")
    }

    func testCriticalPressureMarksAnomalous() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Critical"
        // Baseline p90 = 50 MB → default threshold 125 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 700)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 701)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 300 MB > 125 MB ✓; positive slope ✓; pressure .critical ✓
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .critical)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "critical memory pressure must also satisfy condition 3 and mark process anomalous")
    }

    func testMemoryDropBelowThresholdClearsAnomalyStartDate() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Recovery"
        // Baseline p90 = 100 MB → default threshold = 250 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 100, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Pre-seed anomalyStartDate as if it was already flagged
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 200 MB < 250 MB threshold → condition 1 fails → anomalyStartDate must be cleared
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 200)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(detector.anomalyStartDates[bundleID],
                     "anomalyStartDate must be cleared when memory drops below threshold")
    }

    func testNilBundleIdentifierProcessIsSkipped() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        let nilBundleProcess = MenuBarProcess(
            pid: 9999,
            name: "UnbundledApp",
            bundleIdentifier: nil,
            icon: nil,
            cpuFraction: 0,
            cpuHistory: [],
            memoryHistory: [],
            memoryFootprintBytes: UInt64(999 * 1_048_576),
            thermalState: .nominal,
            launchDate: nil
        )

        detector.evaluate(processes: [nilBundleProcess], pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.isEmpty,
                      "process with nil bundleIdentifier must be skipped by anomaly detection")
    }

    func testAggressiveSensitivityLowersThreshold() {
        UserDefaults.standard.set("aggressive", forKey: "sensitivity")
        defer { UserDefaults.standard.removeObject(forKey: "sensitivity") }

        let bundleID = "com.test.Aggressive"
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // Baseline p90 = 100 MB → aggressive threshold = 100 × 1.5 = 150 MB (active + aggressive)
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 100, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 800)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 150, pid: 801)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 160 MB > 150 MB threshold ✓; positive slope ✓; pressure .warning ✓
        // Explicitly set phase to "active" so sensitivity multiplier applies.
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 160)],
                          pressure: .warning,
                          bundleIDPhases: [bundleID: "active"])

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "160 MB must trigger aggressive threshold of 150 MB (p90 × 1.5)")
    }

    func testAnomalyUnder10MinFlagsViewButNoNotification() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Under10Min"
        // Baseline p90 = 50 MB → default threshold = 125 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 900)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 901)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Anomaly started only 5 minutes ago — below the 10-min persistence threshold for notifications
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-5 * 60)

        // 300 MB > 125 MB ✓; positive slope ✓; pressure .warning ✓
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "process must be flagged in the view even when anomaly duration is less than 10 min")
        XCTAssertNil(detector.lastNotificationDates[bundleID],
                     "no notification must be sent when anomaly has persisted for less than 10 minutes")
    }

    func testMultipleProcessesPartiallyAnomalous() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleA = "com.test.Multi.A"
        let bundleB = "com.test.Multi.B"

        // Baseline for A: p90 = 50 MB → threshold = 50 × 2.5 = 125 MB
        let baseProcsA = (1...10).map { i in
            makeProcess(bundleID: bundleA, memoryMB: 50, pid: Int32(i))
        }
        // Baseline for B: p90 = 200 MB → threshold = 200 × 2.5 = 500 MB
        let baseProcsB = (1...10).map { i in
            makeProcess(bundleID: bundleB, memoryMB: 200, pid: Int32(100 + i))
        }
        store.persistSamples(baseProcsA + baseProcsB)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Positive trend samples for both, 1 second apart
        store.persistSamples([
            makeProcess(bundleID: bundleA, memoryMB: 100, pid: 1000),
            makeProcess(bundleID: bundleB, memoryMB: 200, pid: 1001)
        ])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([
            makeProcess(bundleID: bundleA, memoryMB: 200, pid: 1002),
            makeProcess(bundleID: bundleB, memoryMB: 300, pid: 1003)
        ])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleA] = Date().addingTimeInterval(-11 * 60)
        detector.anomalyStartDates[bundleB] = Date().addingTimeInterval(-11 * 60)

        // A at 300 MB > 125 MB threshold ✓; B at 300 MB < 500 MB threshold ✗
        detector.evaluate(processes: [
            makeProcess(bundleID: bundleA, memoryMB: 300),
            makeProcess(bundleID: bundleB, memoryMB: 300)
        ], pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleA),
                      "A must be flagged: 300 MB > 125 MB threshold (p90 50 × 2.5)")
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleB),
                       "B must NOT be flagged: 300 MB < 500 MB threshold (p90 200 × 2.5)")
    }

    func testBouncerSelfExclusionGuard() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())

        // Pass Bouncer at extreme memory under warning pressure.
        // The guard `bundleID != "com.allenz.Bouncer"` fires before any baseline lookup.
        let bouncerProcess = MenuBarProcess(
            pid: 9999,
            name: "Bouncer",
            bundleIdentifier: "com.allenz.Bouncer",
            icon: nil,
            cpuFraction: 0,
            cpuHistory: [],
            memoryHistory: [],
            memoryFootprintBytes: UInt64(9999 * 1_048_576),
            thermalState: .nominal,
            launchDate: nil
        )
        detector.evaluate(processes: [bouncerProcess], pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains("com.allenz.Bouncer"),
                       "Bouncer self-exclusion guard must prevent com.allenz.Bouncer from being flagged")
    }

    func testActiveAlertEventIDsSetOnAnomalyConfirmed() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.AlertEventSet"

        // 35 samples → sample_count = 35 (≥ 30), baseline p90 ≈ 100 MB
        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 9000)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 9100)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 9101)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Pre-seed anomalyStartDate 11 minutes ago to satisfy the 10-min persistence gate
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 300 MB > p90(100) × 2.5 = 250 MB ✓; positive slope ✓; pressure .warning ✓; 35 samples ≥ 30 ✓
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "active"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(detector.activeAlertEventIDs[bundleID],
                        "activeAlertEventIDs must contain an entry after anomaly is confirmed")
        XCTAssertGreaterThanOrEqual(detector.activeAlertEventIDs[bundleID] ?? -1, 1,
                                    "activeAlertEventIDs entry must be a valid row ID (>= 1)")
    }

    func testActiveAlertEventIDsClearedOnResolve() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.AlertEventClear"

        // Build a baseline so condition 1 can be checked (p90 = 100 MB, threshold = 250 MB)
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 100, pid: Int32(9200 + i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Insert a real alert event and pre-seed it into the detector
        let eventID = store.insertAlertEvent(
            bundleID: bundleID, appName: "ClearApp",
            startedAt: Date().addingTimeInterval(-15 * 60),
            peakMemoryMB: 400, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(eventID, 1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.activeAlertEventIDs[bundleID] = eventID

        // 50 MB < 250 MB → condition 1 fails → resolvedBundleIDs cleanup fires
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 50)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "active"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        Thread.sleep(forTimeInterval: 0.1)   // wait for async closeAlertEvent

        XCTAssertNil(detector.activeAlertEventIDs[bundleID],
                     "activeAlertEventIDs must be cleared when the anomaly resolves")

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertNotNil(timeline.first?.endedAt,
                        "ended_at must be set in the DB after the resolved anomaly closes its event")
    }

    func testRecordUserActionClosesEventWithCorrectAction() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.UserAction"

        let eventID = store.insertAlertEvent(
            bundleID: bundleID, appName: "UserActionApp",
            startedAt: Date().addingTimeInterval(-5 * 60),
            peakMemoryMB: 500, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(eventID, 1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.activeAlertEventIDs[bundleID] = eventID

        detector.recordUserAction("quit", for: bundleID)
        Thread.sleep(forTimeInterval: 0.1)   // wait for async closeAlertEvent

        XCTAssertNil(detector.activeAlertEventIDs[bundleID],
                     "activeAlertEventIDs must be cleared after recordUserAction")

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(timeline.first?.userAction, "quit",
                       "user_action in DB must be 'quit' after recordUserAction(\"quit\")")
    }

    func testNotificationBodyFormatsGBWhenOver1000MB() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.GBFormat"

        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 9300)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 9400)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 9401)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 1200 MB >> p90(100) × 2.5 = 250 MB threshold; 37 samples ≥ 30
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 1200)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "active"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(detector.lastSentNotificationBody,
                        "notification body must be set for 1200 MB above active threshold")
        XCTAssertTrue(detector.lastSentNotificationBody?.contains("GB") == true,
                      "notification body must use GB formatting when memory >= 1000 MB")
        XCTAssertFalse(detector.lastSentNotificationBody?.contains("MB") == true,
                       "notification body must NOT contain 'MB' when memory is formatted as GB")
    }

    func testRecordUserActionWithInvalidActionIsNoOp() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.InvalidAction"

        let eventID = store.insertAlertEvent(
            bundleID: bundleID, appName: "InvalidActionApp",
            startedAt: Date().addingTimeInterval(-5 * 60),
            peakMemoryMB: 300, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(eventID, 1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.activeAlertEventIDs[bundleID] = eventID

        detector.recordUserAction("invalidAction", for: bundleID)

        // Invalid action must not touch activeAlertEventIDs
        XCTAssertNotNil(detector.activeAlertEventIDs[bundleID],
                        "activeAlertEventIDs must not be cleared for an invalid action")

        Thread.sleep(forTimeInterval: 0.15)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertNil(timeline.first?.endedAt,
                     "event must remain open (endedAt nil) after recordUserAction with invalid action")
    }

    func testSwapCurrentlyActivePropagatesSwapCorrelated() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.SwapCorrelated"

        seedSamples(store: store, bundleID: bundleID, memoryMB: 100, count: 35, pidBase: 9500)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 9600)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 9601)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)
        detector.swapCurrentlyActive = true

        // 300 MB > p90(100) × 2.5 = 250 MB threshold (active phase, 37 samples ≥ 30)
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "active"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        Thread.sleep(forTimeInterval: 0.3)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertFalse(timeline.isEmpty, "alert timeline must contain an event after confirmed anomaly")
        XCTAssertTrue(timeline.first?.swapCorrelated == true,
                      "swapCorrelated must be true when swapCurrentlyActive was set before evaluate()")
    }

    func testIgnoredPhaseInBundleIDPhasesSkipsProcess() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.IgnoredPhase"

        // Baseline p90 = 50 MB → any phase threshold well below 999 MB
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(9700 + i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        // Two trend samples 1 second apart → positive slope
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 9800)])
        Thread.sleep(forTimeInterval: 1.1)
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 200, pid: 9801)])
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        // 999 MB is way above any threshold, but bundleIDPhases marks the state as "ignored"
        // This tests the `state != "ignored"` guard in evaluate(), distinct from prefs.ignoredBundleIDs.
        detector.evaluate(
            processes: [makeProcess(bundleID: bundleID, memoryMB: 999)],
            pressure: .warning,
            bundleIDPhases: [bundleID: "ignored"]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "process with 'ignored' phase in bundleIDPhases must be skipped regardless of memory level")
    }
}
