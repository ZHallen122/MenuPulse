import XCTest

final class MenuBarDiagnosticTests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        // Place app outside the 3-day learning period by default so tests that
        // exercise anomaly detection are not silently suppressed. Tests that
        // specifically need the learning period active override this locally.
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")
    }

    // MARK: - Helpers

    private func makeProcess(bundleID: String, memoryMB: Double, pid: Int32 = 1234) -> MenuBarProcess {
        MenuBarProcess(
            pid: pid,
            name: "TestApp",
            bundleIdentifier: bundleID,
            icon: nil,
            cpuFraction: 0,
            cpuHistory: [],
            memoryHistory: [],
            memoryFootprintBytes: UInt64(memoryMB * 1_048_576),
            thermalState: .nominal,
            launchDate: nil
        )
    }

    // MARK: - linearRegressionSlope

    func testSlopePositiveForIncreasingMemory() {
        let detector = AnomalyDetector(dataStore: DataStore(path: ":memory:"), prefs: PreferencesManager())
        let now = Date()
        let samples: [(memoryMB: Double, timestamp: Date)] = [
            (100, now),
            (150, now.addingTimeInterval(600)),
            (200, now.addingTimeInterval(1200))
        ]
        XCTAssertGreaterThan(detector.linearRegressionSlope(samples), 0)
    }

    func testSlopeNegativeForDecreasingMemory() {
        let detector = AnomalyDetector(dataStore: DataStore(path: ":memory:"), prefs: PreferencesManager())
        let now = Date()
        let samples: [(memoryMB: Double, timestamp: Date)] = [
            (200, now),
            (150, now.addingTimeInterval(600)),
            (100, now.addingTimeInterval(1200))
        ]
        XCTAssertLessThan(detector.linearRegressionSlope(samples), 0)
    }

    func testSlopeZeroForFlatMemory() {
        let detector = AnomalyDetector(dataStore: DataStore(path: ":memory:"), prefs: PreferencesManager())
        let now = Date()
        let samples: [(memoryMB: Double, timestamp: Date)] = [
            (100, now),
            (100, now.addingTimeInterval(600)),
            (100, now.addingTimeInterval(1200))
        ]
        XCTAssertEqual(detector.linearRegressionSlope(samples), 0, accuracy: 0.0001)
    }

    // MARK: - DataStore: sample storage

    func testPersistSamplesAndRetrieve() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: "com.test.Store", memoryMB: 100)])
        Thread.sleep(forTimeInterval: 0.1)

        let samples = store.recentSamples(for: "com.test.Store", since: Date().addingTimeInterval(-3600))
        XCTAssertFalse(samples.isEmpty, "persisted sample should be retrievable")
        XCTAssertEqual(samples.first?.memoryMB ?? 0, 100, accuracy: 0.01)
    }

    // MARK: - DataStore: p90 baseline computation

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

    // MARK: - DataStore: 7-day purge

    func testPurgeDoesNotRemoveFreshSamples() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: "com.test.Purge", memoryMB: 80)])
        Thread.sleep(forTimeInterval: 0.1)

        store.purgeOldSamples()
        Thread.sleep(forTimeInterval: 0.1)

        // Freshly inserted sample is within 7 days — must survive the purge
        let samples = store.recentSamples(for: "com.test.Purge", since: Date().addingTimeInterval(-3600))
        XCTAssertFalse(samples.isEmpty, "fresh samples (< 7 days old) must survive purgeOldSamples")
    }

    // MARK: - AnomalyDetector: condition 3 — system memory pressure

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

    // MARK: - AnomalyDetector: condition 1 — memory above p90 × multiplier

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

    // MARK: - AnomalyDetector: condition 2 — positive memory slope

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

    // MARK: - AnomalyDetector: all 3 conditions met + 10-min persistence

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

    // MARK: - AnomalyDetector: 24-hour notification cooldown

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

    // MARK: - AnomalyDetector: learning period suppresses anomalies

    func testLearningPeriodSuppressesAnomalies() {
        // Simulate a just-launched app (learning period active)
        UserDefaults.standard.set(Date(), forKey: "firstLaunchDate")

        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Learning"
        let baseProcs = (1...10).map { i in
            makeProcess(bundleID: bundleID, memoryMB: 50, pid: Int32(i))
        }
        store.persistSamples(baseProcs)
        Thread.sleep(forTimeInterval: 0.1)
        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.1)

        let detector = AnomalyDetector(dataStore: store, prefs: PreferencesManager())
        // Pre-seed as if anomaly started 11 minutes ago
        detector.anomalyStartDates[bundleID] = Date().addingTimeInterval(-11 * 60)

        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 300)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.isEmpty,
                      "learning period must suppress all anomaly detection")
        XCTAssertTrue(detector.anomalyStartDates.isEmpty,
                      "evaluate() must clear anomalyStartDates during learning period")
    }

    // MARK: - AnomalyDetector: ignored bundle IDs are excluded

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

    // MARK: - AnomalyDetector: departed process clears anomalyStartDate

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

    // MARK: - AnomalyDetector: conservative sensitivity raises threshold

    func testConservativeSensitivityRequiresHigherThreshold() {
        UserDefaults.standard.set("conservative", forKey: "sensitivity")
        defer { UserDefaults.standard.removeObject(forKey: "sensitivity") }

        // Not in learning period
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")

        let bundleID = "com.test.Conservative"
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // Baseline p90 = 100 MB → conservative threshold = 100 × 4.0 = 400 MB
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
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 350)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(detector.anomalousBundleIDs.contains(bundleID),
                       "350 MB must not trigger conservative threshold of 400 MB (p90 × 4.0)")
    }

    // MARK: - DataStore: nil baseline for unknown bundle ID

    func testBaselineNilForUnknownBundleID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let baseline = store.baseline(for: "com.test.NeverSeen")
        XCTAssertNil(baseline, "baseline must be nil when no samples have been persisted for the bundle ID")
    }

    // MARK: - PreferencesManager: ignoredBundleIDs parsing trims whitespace

    func testIgnoredBundleIDsParsingTrimsWhitespace() {
        let prefs = PreferencesManager()
        prefs.ignoredBundleIDsRaw = " com.a , com.b , , com.c "
        XCTAssertEqual(prefs.ignoredBundleIDs, ["com.a", "com.b", "com.c"],
                       "ignoredBundleIDs must split on comma, trim whitespace, and drop empty entries")
    }

    // MARK: - PreferencesManager: ignoredBundleIDs setter joins with comma

    func testIgnoredBundleIDsSetterJoinsWithComma() {
        let prefs = PreferencesManager()
        prefs.ignoredBundleIDs = ["com.a", "com.b"]
        XCTAssertEqual(prefs.ignoredBundleIDsRaw, "com.a,com.b",
                       "ignoredBundleIDs setter must join entries with comma into ignoredBundleIDsRaw")
    }

    // MARK: - AnomalyDetector: critical pressure triggers anomaly

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

    // MARK: - AnomalyDetector: memory drops below threshold clears anomalyStartDate

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

    // MARK: - AnomalyDetector: nil bundleIdentifier process is skipped

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

    // MARK: - AnomalyDetector: aggressive sensitivity lowers threshold

    func testAggressiveSensitivityLowersThreshold() {
        UserDefaults.standard.set("aggressive", forKey: "sensitivity")
        defer { UserDefaults.standard.removeObject(forKey: "sensitivity") }

        let bundleID = "com.test.Aggressive"
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        // Baseline p90 = 100 MB → aggressive threshold = 100 × 1.5 = 150 MB
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
        detector.evaluate(processes: [makeProcess(bundleID: bundleID, memoryMB: 160)],
                          pressure: .warning)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(detector.anomalousBundleIDs.contains(bundleID),
                      "160 MB must trigger aggressive threshold of 150 MB (p90 × 1.5)")
    }

    // MARK: - DataStore: recentSamples respects since cutoff

    func testRecentSamplesRespectsSinceCutoff() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: "com.test.Since", memoryMB: 100)])
        Thread.sleep(forTimeInterval: 0.1)

        // Query with a cutoff 1 second after the insert — the sample was recorded before this
        let samples = store.recentSamples(for: "com.test.Since", since: Date().addingTimeInterval(1))
        XCTAssertTrue(samples.isEmpty,
                      "recentSamples(since:) must exclude samples with timestamps before the cutoff")
    }
}
