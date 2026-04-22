import XCTest

final class ProcessMonitorEnumerationTests: MenuBarDiagnosticTestCase {

    func testPersistAndAdvanceLifecycleThrottleGuard() {
        // First call (lastPersistTime = distantPast) writes an app lifecycle entry.
        // Second call (lastPersistTime = now) is throttled and must NOT write a new entry.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let monitor = ProcessMonitor(prefs: PreferencesManager(), dataStore: store)
        monitor.lastPersistTime = .distantPast

        let firstBundleID = "com.test.PAL.Throttle.First"
        let firstProcess = makeProcess(bundleID: firstBundleID, memoryMB: 100, pid: 50001)

        // First call must proceed (distantPast satisfies the 30 s threshold).
        monitor.persistAndAdvanceLifecycle(processes: [firstProcess], bundleURLMap: [:])
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(store.appState(for: firstBundleID), "learning_phase_1",
                       "first call must write a lifecycle entry for the new app")

        // Set lastPersistTime to now — second call with a new bundle ID must be throttled.
        monitor.lastPersistTime = Date()
        let secondBundleID = "com.test.PAL.Throttle.Second"
        let secondProcess = makeProcess(bundleID: secondBundleID, memoryMB: 100, pid: 50002)

        monitor.persistAndAdvanceLifecycle(processes: [secondProcess], bundleURLMap: [:])
        Thread.sleep(forTimeInterval: 0.1)

        // The second bundle ID must have NO lifecycle entry — the call was throttled.
        XCTAssertNil(store.lifecycleEntry(for: secondBundleID),
                     "throttled second call must not create a lifecycle entry for the new process")
    }

    func testPersistAndAdvanceLifecycleNewApp() {
        // A brand-new bundle ID must be inserted into app_lifecycle as learning_phase_1.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let monitor = ProcessMonitor(prefs: PreferencesManager(), dataStore: store)
        monitor.lastPersistTime = .distantPast

        let bundleID = "com.test.PAL.NewApp"
        let process = makeProcess(bundleID: bundleID, memoryMB: 50, pid: 50002)

        monitor.persistAndAdvanceLifecycle(processes: [process], bundleURLMap: [:])
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(store.appState(for: bundleID), "learning_phase_1",
                       "brand-new app must enter learning_phase_1 on first encounter")
    }

    func testPersistAndAdvanceLifecycleStaleAppResets() {
        // An app with state == "stale" in DB must restart in learning_phase_1 when it reappears.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.PAL.StaleReset"
        store.updateAppLifecycle(bundleID: bundleID, state: "stale", version: nil, lastSeen: Date())
        Thread.sleep(forTimeInterval: 0.1)

        let monitor = ProcessMonitor(prefs: PreferencesManager(), dataStore: store)
        monitor.lastPersistTime = .distantPast

        let process = makeProcess(bundleID: bundleID, memoryMB: 50, pid: 50003)
        monitor.persistAndAdvanceLifecycle(processes: [process], bundleURLMap: [:])
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(store.appState(for: bundleID), "learning_phase_1",
                       "stale app re-appearing must restart in learning_phase_1")
    }

    func testPersistAndAdvanceLifecyclePhaseAdvancement() {
        // Pre-seed lifecycleCache with learningStartedAt 5 hours ago → phase must advance to learning_phase_2.
        // Phase thresholds: <4h → phase_1, <24h → phase_2, <72h → phase_3, else → active.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.PAL.PhaseAdvance"
        let fiveHoursAgo = Date().addingTimeInterval(-5 * 3600)

        let monitor = ProcessMonitor(prefs: PreferencesManager(), dataStore: store)
        monitor.lastPersistTime = .distantPast

        // Inject cache entry directly: state = phase_1, learningStartedAt = 5 hours ago.
        // persistAndAdvanceLifecycle will see the cache hit and then advance the phase.
        monitor.lifecycleCache[bundleID] = ProcessMonitor.LifecycleEntry(
            state: "learning_phase_1",
            version: nil,
            learningStartedAt: fiveHoursAgo,
            lastSeen: Date()
        )

        let process = makeProcess(bundleID: bundleID, memoryMB: 50, pid: 50004)
        monitor.persistAndAdvanceLifecycle(processes: [process], bundleURLMap: [:])
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(store.appState(for: bundleID), "learning_phase_2",
                       "app with learningStartedAt 5 hours ago must advance to learning_phase_2 (threshold: 4 h)")
    }
}
