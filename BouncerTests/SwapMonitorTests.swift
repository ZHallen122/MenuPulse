import XCTest

final class SwapMonitorTests: BouncerTestCase {

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

    func testSwapNotificationBody() {
        let swapMon = SwapMonitor()
        swapMon.swapUsedBytes = UInt64(2.1 * 1_073_741_824)
        let processes = [makeProcess(bundleID: "com.tinyspeck.slackmacgap", memoryMB: 1126.4)]
        let content = swapMon.buildNotificationContent(processes: processes)
        XCTAssertTrue(content.title.contains("Mac is using disk as overflow memory"),
                      "notification title must contain 'Mac is using disk as overflow memory'")
        XCTAssertTrue(content.body.contains("Biggest contributor"),
                      "notification body must name the biggest memory contributor")
    }

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
        XCTAssertTrue(criticalContent.title.lowercased().contains("swapping"),
                      "swapCritical notification title must convey urgency")
    }

    func testSwapCooldownExpiryAllowsNotification() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 1 * 1_073_741_824
        // Simulate a notification sent 3601 seconds ago (just past the 1-hour cooldown)
        monitor.lastSwapNotificationDate = Date().addingTimeInterval(-3601)
        let sent = monitor.checkAndMaybeNotify(processes: [])
        XCTAssertTrue(sent, "checkAndMaybeNotify must return true when cooldown has expired (> 3600 s)")
    }

    func testSwapNotificationBodyWithNoProcesses() {
        let monitor = SwapMonitor()
        monitor.swapUsedBytes = 1 * 1_073_741_824
        let content = monitor.buildNotificationContent(processes: [])
        XCTAssertFalse(content.body.contains("Biggest contributor"),
                       "notification body must NOT mention 'Biggest contributor' when process list is empty")
    }

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

    func testWindowCapEvictsOldestSample() {
        // Inject 11 samples: first at 0 MB, then 10 more at [128, 256, ..., 1280 MB].
        // maxSamples = 10, so after cap the 0 MB sample is evicted.
        // Window = [128..1280 MB], min = 128 MB, newest = 1280 MB.
        // delta = 1280 - 128 = 1152 MB = 1207959552 bytes > 1 GiB → swapCritical.
        // If 0 MB were NOT evicted: min = 0, newest = 1152 MB, delta = 1152 MB → also swapCritical;
        // swapUsedBytes would be 1152 MB instead of 1280 MB — proving different eviction state.
        let monitor = SwapMonitor()
        let now = Date()
        monitor.injectSample(swapBytes: 0, compressedBytes: 0, at: now.addingTimeInterval(-330))
        for i in 1...10 {
            let swapBytes = UInt64(i) * 128 * MB
            monitor.injectSample(swapBytes: swapBytes, compressedBytes: 0,
                                 at: now.addingTimeInterval(Double(i - 10) * 30))
        }
        // After cap: exactly 10 samples [128..1280 MB]; 0 MB sample was evicted.
        XCTAssertEqual(monitor.swapState, .swapCritical,
                       "window cap evicts 0 MB sample → min = 128 MB, delta = 1152 MB → swapCritical")
        XCTAssertEqual(monitor.swapUsedBytes, 1280 * MB,
                       "swapUsedBytes must equal the newest injected sample (1280 MB) after cap eviction")
    }

    func testWindowExactlyAtCapacityNoOverflow() {
        // Inject exactly 10 samples (= maxSamples). No eviction should occur; no crash.
        // Samples: 0 MB, 128 MB, ..., 1152 MB (10 samples).
        // min = 0, newest = 1152 MB, delta = 1152 MB > 1 GiB → swapCritical.
        let monitor = SwapMonitor()
        let now = Date()
        for i in 0..<10 {
            let swapBytes = UInt64(i) * 128 * MB
            monitor.injectSample(swapBytes: swapBytes, compressedBytes: 0,
                                 at: now.addingTimeInterval(Double(i - 9) * 30))
        }
        XCTAssertEqual(monitor.swapState, .swapCritical,
                       "exactly 10 samples with 1152 MB delta must produce swapCritical — no crash at capacity")
        XCTAssertEqual(monitor.swapUsedBytes, 9 * 128 * MB,
                       "swapUsedBytes must be the newest (9th × 128 MB = 1152 MB) after 10 samples at capacity")
    }
}
