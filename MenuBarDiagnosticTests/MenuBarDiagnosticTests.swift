import XCTest
import AppKit

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

    // MARK: - AnomalyDetector: phase_1 below 30 samples suppresses notification but not icon tint

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

    // MARK: - SwapMonitor: delta-based swapState computation

    private let MB: UInt64 = 1_048_576
    private let GB: UInt64 = 1_073_741_824

    func testSwapStateNormalWhenNoSamples() {
        let monitor = SwapMonitor()
        // Fresh monitor with no samples injected → delta is 0 → normal
        XCTAssertEqual(monitor.swapState, .normal,
                       "swapState must be .normal when no samples have been injected")
    }

    func testSwapStateNormalWhenSingleSample() {
        let monitor = SwapMonitor()
        // A single sample produces no delta (need at least 2 samples to compute delta)
        monitor.injectSample(swapBytes: 2 * GB, compressedBytes: 0, at: Date())
        XCTAssertEqual(monitor.swapState, .normal,
                       "swapState must be .normal with only one sample (no delta computable)")
    }

    func testSwapStateNormalWhenLargeBytesButZeroDelta() {
        // Large absolute swap value with zero delta → still normal
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 5 * GB, compressedBytes: 0, at: now.addingTimeInterval(-60))
        monitor.injectSample(swapBytes: 5 * GB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .normal,
                       "swapState must be .normal when swap is large but delta is zero (no growth)")
    }

    func testSwapStateSwapMinorAt100MB() {
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 100 * MB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapMinor,
                       "swapState must be .swapMinor when swap delta is exactly 100 MB in 5 min")
    }

    func testSwapStateSwapMinorBelow500MB() {
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 499 * MB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapMinor,
                       "swapState must be .swapMinor when swap delta is 499 MB (just below significant threshold)")
    }

    func testSwapStateSwapSignificantAt500MB() {
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 500 * MB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapSignificant,
                       "swapState must be .swapSignificant when swap delta is exactly 500 MB in 5 min")
    }

    func testSwapStateSwapSignificantBelow1GB() {
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: GB - 1, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapSignificant,
                       "swapState must be .swapSignificant when swap delta is just below 1 GB")
    }

    func testSwapStateSwapCriticalAt1GB() {
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: GB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapCritical,
                       "swapState must be .swapCritical when swap delta is exactly 1 GB in 5 min")
    }

    func testSwapStateCompressedGrowingAt300MB() {
        let monitor = SwapMonitor()
        let now = Date()
        // Compressed grows 300 MB, swap stays at 0 → compressedGrowing
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 0, compressedBytes: 300 * MB, at: now)
        XCTAssertEqual(monitor.swapState, .compressedGrowing,
                       "swapState must be .compressedGrowing when compressed delta >= 300 MB with no swap delta")
    }

    func testSwapStateSwapTakesPriorityOverCompressed() {
        // When both swap (minor) and compressed (growing) thresholds are met, swap wins
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 100 * MB, compressedBytes: 300 * MB, at: now)
        XCTAssertEqual(monitor.swapState, .swapMinor,
                       "swapMinor must take priority over compressedGrowing when both thresholds are met")
    }

    func testSwapStateNormalWhenBelowAllThresholds() {
        let monitor = SwapMonitor()
        let now = Date()
        // 99 MB swap delta and 299 MB compressed delta — both below thresholds
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 99 * MB, compressedBytes: 299 * MB, at: now)
        XCTAssertEqual(monitor.swapState, .normal,
                       "swapState must be .normal when all deltas are below thresholds")
    }

    // MARK: - SwapMonitor: notification body

    func testSwapNotificationBody() {
        let swapMon = SwapMonitor()
        swapMon.swapUsedBytes = UInt64(2.1 * 1_073_741_824)
        let processes = [makeProcess(bundleID: "com.tinyspeck.slackmacgap", memoryMB: 1126.4)]
        let content = swapMon.buildNotificationContent(processes: processes)
        XCTAssertTrue(content.title.contains("Your Mac is using disk as memory"),
                      "notification title must contain 'Your Mac is using disk as memory'")
        XCTAssertTrue(content.body.contains("Biggest contributor"),
                      "notification body must name the biggest memory contributor")
    }

    // MARK: - SwapMonitor: 1-hour notification cooldown

    func testSwapNotificationCooldown() {
        let swapMon = SwapMonitor()
        swapMon.swapUsedBytes = 1 * 1_073_741_824

        // First call should go through (no prior date).
        let firstSent = swapMon.checkAndMaybeNotify(processes: [])
        XCTAssertTrue(firstSent, "first swap notification must be enqueued")

        // Immediate second call must be blocked by the 1-hour cooldown.
        let secondSent = swapMon.checkAndMaybeNotify(processes: [])
        XCTAssertFalse(secondSent, "second swap notification within 1 hour must be suppressed")

        // lastSwapNotificationDate must not have changed on the blocked call.
        let dateAfterBlock = swapMon.lastSwapNotificationDate
        swapMon.checkAndMaybeNotify(processes: [])
        XCTAssertEqual(
            swapMon.lastSwapNotificationDate?.timeIntervalSince1970 ?? 0,
            dateAfterBlock?.timeIntervalSince1970 ?? 0,
            accuracy: 1.0,
            "lastSwapNotificationDate must remain unchanged during cooldown"
        )
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

    // MARK: - SwapMonitor: notification firing rules (significant/critical only)

    func testNoNotificationForSwapMinor() {
        // swapMinor must not trigger a notification
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 150 * MB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapMinor)
        // checkAndMaybeNotify is the gate — swapMinor should NOT be driven to notify automatically.
        // Verify that the sample() notification trigger only fires for significant/critical by
        // checking that lastSwapNotificationDate is nil after injecting a minor sample.
        XCTAssertNil(monitor.lastSwapNotificationDate,
                     "injectSample must not auto-notify; notification is only sent by the sample() trigger for significant/critical")
    }

    func testNoNotificationForCompressedGrowing() {
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-240))
        monitor.injectSample(swapBytes: 0, compressedBytes: 400 * MB, at: now)
        XCTAssertEqual(monitor.swapState, .compressedGrowing)
        XCTAssertNil(monitor.lastSwapNotificationDate,
                     "compressedGrowing must not trigger a notification")
    }

    func testNotificationForSwapSignificant() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 600 * MB   // absolute bytes for notification body
        // checkAndMaybeNotify is exposed and called directly — simulates what sample() does
        // when swapState == .swapSignificant
        let sent = monitor.checkAndMaybeNotify(processes: [])
        XCTAssertTrue(sent, "checkAndMaybeNotify must return true for first call (significant scenario)")
    }

    func testNotificationForSwapCritical() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 2 * GB
        let sent = monitor.checkAndMaybeNotify(processes: [])
        XCTAssertTrue(sent, "checkAndMaybeNotify must return true for first call (critical scenario)")
    }

    func testCriticalNotificationBodyDifferentFromSignificant() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 2 * GB
        let criticalContent = monitor.buildNotificationContent(processes: [], state: .swapCritical)
        let significantContent = monitor.buildNotificationContent(processes: [], state: .swapSignificant)
        XCTAssertNotEqual(criticalContent.title, significantContent.title,
                          "swapCritical and swapSignificant notifications must have different titles")
        XCTAssertTrue(criticalContent.title.lowercased().contains("critical"),
                      "swapCritical notification title must convey urgency")
    }

    // MARK: - SwapMonitor: cooldown expiry allows re-notification

    func testSwapCooldownExpiryAllowsNotification() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 1 * 1_073_741_824
        // Simulate a notification sent 3601 seconds ago (just past the 1-hour cooldown)
        monitor.lastSwapNotificationDate = Date().addingTimeInterval(-3601)
        let sent = monitor.checkAndMaybeNotify(processes: [])
        XCTAssertTrue(sent, "checkAndMaybeNotify must return true when cooldown has expired (> 3600 s)")
    }

    // MARK: - SwapMonitor: notification body without processes

    func testSwapNotificationBodyWithNoProcesses() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 1 * 1_073_741_824
        let content = monitor.buildNotificationContent(processes: [])
        XCTAssertFalse(content.body.contains("Biggest contributor"),
                       "notification body must NOT mention 'Biggest contributor' when process list is empty")
    }

    // MARK: - SwapMonitor: start/stop lifecycle smoke tests

    func testStartThenStopMonitoringDoesNotCrash() {
        let monitor = SwapMonitor()
        monitor.startMonitoring()
        monitor.stopMonitoring()
        // If we reach here, no crash occurred.
    }

    func testStopMonitoringOnNeverStartedDoesNotCrash() {
        let monitor = SwapMonitor()
        monitor.stopMonitoring()
        // stopMonitoring on a monitor that was never started must not crash.
    }

    // MARK: - DataStore: recentSamples returns empty for unknown bundle ID

    func testRecentSamplesEmptyForUnknownBundleID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let samples = store.recentSamples(for: "com.test.NeverInserted", since: Date().addingTimeInterval(-3600))
        XCTAssertTrue(samples.isEmpty, "recentSamples must return empty for a bundle ID with no persisted samples")
    }

    // MARK: - DataStore: baseline is nil before recomputeBaselines is called

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

    // MARK: - linearRegressionSlope: single sample returns 0.0 (denominator guard)

    func testLinearRegressionSlopeSingleSample() {
        let detector = AnomalyDetector(dataStore: DataStore(path: ":memory:"), prefs: PreferencesManager())
        let result = detector.linearRegressionSlope([(memoryMB: 100, timestamp: Date())])
        XCTAssertEqual(result, 0.0, "linearRegressionSlope must return 0.0 for a single-sample array (denominator guard path)")
    }

    // MARK: - AnomalyDetector: anomaly < 10 min flags view but suppresses notification

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

    // MARK: - AnomalyDetector: multiple processes, only those above threshold are anomalous

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

    // MARK: - Icon tint

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

    // MARK: - PreferencesManager: isInLearningPeriod true and false

    func testIsInLearningPeriodTrueAndFalse() {
        // Just launched — learning period must be active
        UserDefaults.standard.set(Date(), forKey: "firstLaunchDate")
        let prefsNew = PreferencesManager()
        XCTAssertTrue(prefsNew.isInLearningPeriod,
                      "isInLearningPeriod must be true when firstLaunchDate is now")

        // Launched 4 days ago — 3-day learning window has expired
        UserDefaults.standard.set(Date().addingTimeInterval(-4 * 86400), forKey: "firstLaunchDate")
        let prefsOld = PreferencesManager()
        XCTAssertFalse(prefsOld.isInLearningPeriod,
                       "isInLearningPeriod must be false when firstLaunchDate is 4 days ago")

        // Restore: push firstLaunchDate well outside learning period for other tests
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")
    }

    // MARK: - SwapMonitor: positive-delta (min-in-window) and spike/sleep-wake filtering

    func testSwapNegativeDeltaDoesNotTriggerAlert() {
        // Swap went down over the window — min-based delta is 0 → normal.
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 2 * GB, compressedBytes: 0, at: now.addingTimeInterval(-60))
        monitor.injectSample(swapBytes: 1 * GB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .normal,
                       "Swap decreased over window → delta is 0 → normal state")
    }

    func testMinBasedDeltaDetectsGrowthAfterDipBelowSignificantThreshold() {
        // Window: 4 GB → 3.4 GB (dip) → 4 GB
        // oldest-based: 4 - 4 = 0 → would be normal (wrong — misses growth from the dip)
        // min-based:    4 - 3.4 = 0.6 GB → swapSignificant (correct)
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 4 * GB, compressedBytes: 0, at: now.addingTimeInterval(-120))
        monitor.injectSample(swapBytes: UInt64(3.4 * Double(GB)), compressedBytes: 0, at: now.addingTimeInterval(-60))
        monitor.injectSample(swapBytes: 4 * GB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapSignificant,
                       "min-based delta: 4 GB newest − 3.4 GB min = 0.6 GB → swapSignificant")
    }

    func testMinBasedDeltaCapturesGrowthDespitePartialRelease() {
        // Window: 2 GB → 1.5 GB (partial release) → 3 GB
        // oldest-based: 3 - 2 = 1 GB → swapCritical
        // min-based:    3 - 1.5 = 1.5 GB → swapCritical (same tier, but correct magnitude)
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 2 * GB, compressedBytes: 0, at: now.addingTimeInterval(-120))
        monitor.injectSample(swapBytes: UInt64(1.5 * Double(GB)), compressedBytes: 0, at: now.addingTimeInterval(-60))
        monitor.injectSample(swapBytes: 3 * GB, compressedBytes: 0, at: now)
        XCTAssertEqual(monitor.swapState, .swapCritical,
                       "3 GB − 1.5 GB window-min = 1.5 GB delta → swapCritical")
    }

    func testSinglePostWakeSampleProducesNoDelta() {
        // After a sleep/wake purge, only one sample exists — count < 2 guard fires → normal.
        let monitor = SwapMonitor()
        monitor.injectSample(swapBytes: 2 * GB, compressedBytes: 0, at: Date())
        XCTAssertEqual(monitor.swapState, .normal,
                       "A single post-wake sample has no delta partner → swapState must be normal")
    }

    func testNearSpikeThresholdIsNotFiltered() {
        // A 3.9 GB delta in one interval is below the 4 GB spike threshold → valid, registers as swapCritical.
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 100 * MB, compressedBytes: 0, at: now.addingTimeInterval(-30))
        monitor.injectSample(swapBytes: 4 * GB, compressedBytes: 0, at: now)
        // 4 GB − 100 MB ≈ 3.9 GB → swapCritical
        XCTAssertEqual(monitor.swapState, .swapCritical,
                       "3.9 GB delta is below the 4 GB spike threshold → valid sample → swapCritical")
    }

    // MARK: - OnboardingView: hasShownOnboarding UserDefaults gate

    func testHasShownOnboardingGate() {
        UserDefaults.standard.removeObject(forKey: "hasShownOnboarding")
        defer { UserDefaults.standard.removeObject(forKey: "hasShownOnboarding") }

        // Default must be false so onboarding is shown on first launch.
        // AppDelegate guard: `guard !UserDefaults.standard.bool(forKey: "hasShownOnboarding") else { return }`
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasShownOnboarding"),
                       "hasShownOnboarding must default to false so onboarding is presented on first launch")

        // Once the user taps Continue the key is set true; onboarding must be suppressed on subsequent launches.
        UserDefaults.standard.set(true, forKey: "hasShownOnboarding")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasShownOnboarding"),
                      "hasShownOnboarding must return true after being set, causing onboarding to be skipped")
    }

    // MARK: - PreferencesManager: automaticUpdateChecks toggle

    func testAutomaticUpdateChecksDefaultAndToggle() {
        UserDefaults.standard.removeObject(forKey: "automaticUpdateChecks")
        defer { UserDefaults.standard.removeObject(forKey: "automaticUpdateChecks") }

        let prefs = PreferencesManager()

        // Default must be true so Sparkle checks for updates automatically out of the box.
        XCTAssertTrue(prefs.automaticUpdateChecks,
                      "automaticUpdateChecks must default to true")

        // Toggling off must persist false to UserDefaults so the setting survives relaunches.
        prefs.automaticUpdateChecks = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "automaticUpdateChecks"),
                       "disabling automaticUpdateChecks must persist false to UserDefaults.standard")
    }

    // MARK: - 6-state baseline lifecycle (section 6.6)

    /// Seed `count` samples for `bundleID` at `memoryMB`, waiting for each async write.
    private func seedSamples(store: DataStore, bundleID: String, memoryMB: Double, count: Int, pidBase: Int32 = 7000) {
        for i in 0..<count {
            store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: memoryMB, pid: pidBase + Int32(i))])
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.1)
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
        XCTAssertTrue(detector.lastSentNotificationTitle?.contains("abnormal") == true,
                      "active-phase notification title must contain 'abnormal'")
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

    // MARK: - Stale-cache eviction: 31-day re-appear scenario

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

    // MARK: - DataStore: alert_events — insertAlertEvent

    func testInsertAlertEventReturnsValidRowID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let rowID = store.insertAlertEvent(
            bundleID: "com.test.AlertInsert",
            appName: "InsertApp",
            startedAt: Date(),
            peakMemoryMB: 150,
            swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(rowID, 1, "insertAlertEvent must return a row ID >= 1")
    }

    // MARK: - DataStore: alert_events — closeAlertEvent

    func testCloseAlertEventSetsEndedAtAndUserAction() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.AlertClose"
        let rowID = store.insertAlertEvent(
            bundleID: bundleID,
            appName: "CloseApp",
            startedAt: Date(),
            peakMemoryMB: 200,
            swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(rowID, 1)

        store.closeAlertEvent(id: rowID, endedAt: Date(), userAction: "restarted")
        Thread.sleep(forTimeInterval: 0.1)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(timeline.count, 1, "timeline must contain the closed event")
        XCTAssertNotNil(timeline.first?.endedAt, "endedAt must be set after closeAlertEvent")
        XCTAssertEqual(timeline.first?.userAction, "restarted",
                       "userAction must be 'restarted' after closeAlertEvent")
    }

    // MARK: - DataStore: alert_events — updateAlertEventPeak MAX semantics

    func testUpdateAlertEventPeakMAXSemantics() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.PeakMax"
        let rowID = store.insertAlertEvent(
            bundleID: bundleID,
            appName: "PeakApp",
            startedAt: Date(),
            peakMemoryMB: 100,
            swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(rowID, 1)

        // Update to a higher value — should grow
        store.updateAlertEventPeak(id: rowID, peakMemoryMB: 200)
        Thread.sleep(forTimeInterval: 0.1)

        let after200 = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(after200.first?.peakMemoryMB ?? 0, 200, accuracy: 0.01,
                       "peak must grow to 200 MB after updating with a higher value")

        // Update to a lower value — MAX semantics must prevent shrinkage
        store.updateAlertEventPeak(id: rowID, peakMemoryMB: 50)
        Thread.sleep(forTimeInterval: 0.1)

        let after50 = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(after50.first?.peakMemoryMB ?? 0, 200, accuracy: 0.01,
                       "peak must remain 200 MB after updateAlertEventPeak with a lower value (MAX semantics)")
    }

    // MARK: - DataStore: alertLeaderboard — aggregates correctly

    func testAlertLeaderboardAggregatesCorrectly() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Leaderboard"
        let now = Date()

        let id1 = store.insertAlertEvent(
            bundleID: bundleID, appName: "LBApp",
            startedAt: now.addingTimeInterval(-120), peakMemoryMB: 300, swapCorrelated: false
        )
        let id2 = store.insertAlertEvent(
            bundleID: bundleID, appName: "LBApp",
            startedAt: now.addingTimeInterval(-60), peakMemoryMB: 350, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(id1, 1)
        XCTAssertGreaterThanOrEqual(id2, 1)

        store.closeAlertEvent(id: id1, endedAt: now.addingTimeInterval(-90), userAction: "restarted")
        store.closeAlertEvent(id: id2, endedAt: now.addingTimeInterval(-30), userAction: "quit")
        Thread.sleep(forTimeInterval: 0.1)

        let leaderboard = store.alertLeaderboard(days: 7)
        let entry = leaderboard.first { $0.bundleID == bundleID }
        XCTAssertNotNil(entry, "leaderboard must contain an entry for the test bundle ID")
        XCTAssertEqual(entry?.alertCount, 2, "alertCount must be 2 for two inserted events")
        XCTAssertEqual(entry?.restartedCount, 1, "restartedCount must be 1")
        XCTAssertEqual(entry?.quitCount, 1, "quitCount must be 1")
    }

    // MARK: - DataStore: alertTimeline — newest-first ordering

    func testAlertTimelineNewestFirst() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Timeline"
        let now = Date()

        // Insert older event first, then newer event
        let olderID = store.insertAlertEvent(
            bundleID: bundleID, appName: "TimeApp",
            startedAt: now.addingTimeInterval(-200), peakMemoryMB: 100, swapCorrelated: false
        )
        let newerID = store.insertAlertEvent(
            bundleID: bundleID, appName: "TimeApp",
            startedAt: now.addingTimeInterval(-100), peakMemoryMB: 200, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(olderID, 1)
        XCTAssertGreaterThanOrEqual(newerID, 1)

        store.closeAlertEvent(id: olderID, endedAt: now.addingTimeInterval(-150), userAction: "none")
        store.closeAlertEvent(id: newerID, endedAt: now.addingTimeInterval(-50), userAction: "none")
        Thread.sleep(forTimeInterval: 0.1)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(timeline.count, 2, "timeline must contain both inserted events")
        XCTAssertGreaterThan(
            timeline[0].startedAt.timeIntervalSince1970,
            timeline[1].startedAt.timeIntervalSince1970,
            "alertTimeline must return entries newest-first (higher startedAt first)"
        )
    }

    // MARK: - DataStore: markIgnored survives markStaleApps

    func testMarkIgnoredSurvivesMarkStaleApps() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.IgnoredStale"

        store.markIgnored(bundleID: bundleID)
        Thread.sleep(forTimeInterval: 0.1)

        // Use a cutoff 1 second in the future so last_seen_at < cutoff is true,
        // which would normally flip the state to "stale". Ignored is a terminal state
        // and must be preserved by the NOT IN ('stale', 'ignored') guard.
        store.markStaleApps(lastSeenCutoff: Date().addingTimeInterval(1))
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(store.appState(for: bundleID), "ignored",
                       "ignored state must survive markStaleApps — it is a terminal state")
    }

    // MARK: - AnomalyDetector: Bouncer self-exclusion guard

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

    // MARK: - AnomalyDetector: activeAlertEventIDs is set when anomaly is confirmed

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

    // MARK: - AnomalyDetector: activeAlertEventIDs is cleared when anomaly resolves

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

    // MARK: - AnomalyDetector: recordUserAction closes the event with the correct action

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

    // MARK: - AppIcon asset wiring

    func testAppIconAppiconsetContainsContentsJson() {
        // Derive project root from this source file's path (not Bundle.main, which is the test runner).
        let testFileURL = URL(fileURLWithPath: #file)
        let projectRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let contentsJsonURL = projectRoot
            .appendingPathComponent("MenuBarDiagnostic")
            .appendingPathComponent("Assets.xcassets")
            .appendingPathComponent("AppIcon.appiconset")
            .appendingPathComponent("Contents.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentsJsonURL.path),
                      "AppIcon.appiconset/Contents.json must exist to wire the app icon into the Xcode asset catalog")
    }
}
