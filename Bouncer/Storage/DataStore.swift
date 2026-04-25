import Foundation
import SQLite3

// MARK: - History data models

/// A row in the Top Offenders leaderboard.
struct AlertLeaderboardEntry: Identifiable {
    /// Uses `bundleID` as the stable `Identifiable` id.
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let alertCount: Int
    /// `nil` when no events have a recorded end time yet.
    let avgDurationSec: Double?
    let lastAlertAt: Date
    let restartedCount: Int
    let quitCount: Int
    let ignoredCount: Int
}

/// One entry in the per-app alert timeline.
struct AlertTimelineEntry: Identifiable {
    let id: Int64
    let startedAt: Date
    let endedAt: Date?
    let peakMemoryMB: Double
    /// "restarted" | "quit" | "ignored" | "none"
    let userAction: String
    let swapCorrelated: Bool

    var durationSec: Double? {
        guard let end = endedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }
}

// MARK: - DataStore

/// Persistent store for per-process memory samples and daily baselines.
///
/// Uses raw SQLite3 (no external dependencies). All database work runs on a
/// private serial queue so callers never block the main thread.
final class DataStore {

    let queue = DispatchQueue(label: "com.mbdiag.datastore")
    var db: OpaquePointer?

    // Pre-compiled SQLite prepared statements for the hottest read paths (baseline
    // lookup, sample count, app state, lifecycle entry, and recent samples). Compiling
    // a statement once with sqlite3_prepare_v2 and rebinding parameters on each use
    // avoids re-parsing SQL on every 2-second sampling tick.
    var cachedBaselineStmt: OpaquePointer?
    var cachedSampleCountStmt: OpaquePointer?
    var cachedAppStateStmt: OpaquePointer?
    var cachedLifecycleEntryStmt: OpaquePointer?
    var cachedRecentSamplesStmt: OpaquePointer?

    init() {
        queue.async { [weak self] in
            self?.openDatabase()
            self?.createTablesIfNeeded()
        }
    }

    /// Opens a SQLite database at an explicit path. Pass `":memory:"` for an
    /// in-memory database suitable for unit tests.
    init(path: String) {
        queue.async { [weak self] in
            var dbPtr: OpaquePointer?
            if sqlite3_open(path, &dbPtr) == SQLITE_OK {
                self?.db = dbPtr
                sqlite3_exec(dbPtr, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            } else {
                NSLog("DataStore: sqlite3_open failed for path %@: %@", path, String(cString: sqlite3_errmsg(dbPtr)))
            }
            self?.createTablesIfNeeded()
        }
    }

    deinit {
        if let stmt = cachedBaselineStmt { sqlite3_finalize(stmt) }
        if let stmt = cachedSampleCountStmt { sqlite3_finalize(stmt) }
        if let stmt = cachedAppStateStmt { sqlite3_finalize(stmt) }
        if let stmt = cachedLifecycleEntryStmt { sqlite3_finalize(stmt) }
        if let stmt = cachedRecentSamplesStmt { sqlite3_finalize(stmt) }
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Inserts a row for every process in `processes`.
    func persistSamples(_ processes: [MenuBarProcess]) {
        queue.async { [weak self] in
            self?.insertSamples(processes)
        }
    }

    /// Deletes samples older than 7 days.
    func purgeOldSamples() {
        queue.async { [weak self] in
            self?.deleteStaleSamples()
        }
    }

    /// Recomputes avg and p90 for every (bundle_id, date) group in the last 7 days.
    func recomputeBaselines() {
        queue.async { [weak self] in
            self?.rebuildBaselines()
        }
    }

    /// Returns the most recent daily baseline for `bundleID`, or `nil` if none.
    func baseline(for bundleID: String) -> (avgMB: Double, medianMB: Double, p90MB: Double)? {
        var result: (Double, Double, Double)?
        queue.sync {
            result = queryBaseline(for: bundleID)
        }
        return result
    }

    /// Returns the total number of sample-insert ticks recorded for `bundleID` in app_lifecycle.
    /// Returns 0 if no lifecycle row exists for the app.
    func sampleCount(for bundleID: String) -> Int {
        var result = 0
        queue.sync {
            result = querySampleCount(for: bundleID)
        }
        return result
    }

    /// Returns raw memory samples for `bundleID` recorded on or after `since`,
    /// ordered ascending by timestamp.
    func recentSamples(for bundleID: String, since: Date) -> [(memoryMB: Double, timestamp: Date)] {
        var result: [(memoryMB: Double, timestamp: Date)] = []
        queue.sync {
            result = queryRecentSamples(for: bundleID, since: since)
        }
        return result
    }

    // MARK: - Lifecycle API (section 6.6)

    /// Returns the lifecycle state for the given bundle ID.
    /// Defaults to `"learning_phase_1"` if the app has no recorded entry.
    func appState(for bundleID: String) -> String {
        var result = "learning_phase_1"
        queue.sync {
            result = queryAppState(for: bundleID)
        }
        return result
    }

    /// Returns the full lifecycle entry for the given bundle ID, or `nil` if not found.
    func lifecycleEntry(for bundleID: String) -> (state: String, version: String?, learningStartedAt: Date?)? {
        var result: (String, String?, Date?)?
        queue.sync {
            result = queryLifecycleEntry(for: bundleID)
        }
        return result
    }

    /// Upserts the app_lifecycle row. Updates state, version, and last_seen_at.
    /// Preserves the existing `learning_started_at` if the row already has one —
    /// use `resetToLearning` to explicitly restart the learning clock.
    func updateAppLifecycle(bundleID: String, state: String, version: String?, lastSeen: Date) {
        queue.async { [weak self] in
            self?.doUpdateAppLifecycle(bundleID: bundleID, state: state, version: version, lastSeen: lastSeen)
        }
    }

    /// Marks all apps last seen before `lastSeenCutoff` in any non-terminal state as `"stale"`.
    /// Terminal states (`"stale"` and `"ignored"`) are never overwritten.
    func markStaleApps(lastSeenCutoff: Date) {
        queue.async { [weak self] in
            self?.doMarkStaleApps(lastSeenCutoff: lastSeenCutoff)
        }
    }

    /// Resets an app to the `"learning_phase_1"` state and records now as `learning_started_at`.
    func resetToLearning(bundleID: String, version: String?) {
        queue.async { [weak self] in
            self?.doResetToLearning(bundleID: bundleID, version: version)
        }
    }

    /// Marks an app as `"ignored"` in app_lifecycle. Ignored apps are never alerted on,
    /// and lifecycle transitions (version change, stale return) will not reset this state.
    func markIgnored(bundleID: String) {
        queue.async { [weak self] in
            self?.doMarkIgnored(bundleID: bundleID)
        }
    }

    /// Returns `true` if the app is in `"learning"` state and `now - learning_started_at < duration`.
    func isInPerAppLearningPeriod(bundleID: String, duration: TimeInterval) -> Bool {
        var result = false
        queue.sync {
            result = doIsInPerAppLearningPeriod(bundleID: bundleID, duration: duration)
        }
        return result
    }

    // MARK: - Alert Events API (History view)

    /// Inserts a new open alert event and returns its row ID.
    /// Runs synchronously so the caller can store the ID immediately.
    @discardableResult
    func insertAlertEvent(
        bundleID: String,
        appName: String,
        startedAt: Date,
        peakMemoryMB: Double,
        swapCorrelated: Bool
    ) -> Int64 {
        var rowID: Int64 = -1
        queue.sync {
            rowID = doInsertAlertEvent(
                bundleID: bundleID, appName: appName,
                startedAt: startedAt, peakMemoryMB: peakMemoryMB,
                swapCorrelated: swapCorrelated
            )
        }
        return rowID
    }

    /// Updates the peak memory for an active alert event.
    func updateAlertEventPeak(id: Int64, peakMemoryMB: Double) {
        queue.async { [weak self] in
            self?.doUpdateAlertEventPeak(id: id, peakMemoryMB: peakMemoryMB)
        }
    }

    /// Marks an alert event as resolved with the given end time and user action.
    /// `userAction` should be one of: "restarted", "quit", "ignored", "none".
    func closeAlertEvent(id: Int64, endedAt: Date, userAction: String) {
        queue.async { [weak self] in
            self?.doCloseAlertEvent(id: id, endedAt: endedAt, userAction: userAction)
        }
    }

    /// Returns leaderboard rows ranked by alert count, for events starting within
    /// the last `days` days.
    func alertLeaderboard(days: Int) -> [AlertLeaderboardEntry] {
        var result: [AlertLeaderboardEntry] = []
        queue.sync {
            result = queryAlertLeaderboard(days: days)
        }
        return result
    }

    /// Returns the alert timeline for a specific app, newest first.
    func alertTimeline(bundleID: String, days: Int) -> [AlertTimelineEntry] {
        var result: [AlertTimelineEntry] = []
        queue.sync {
            result = queryAlertTimeline(bundleID: bundleID, days: days)
        }
        return result
    }

    // MARK: - Private helpers

    private func openDatabase() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("Bouncer", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("DataStore: failed to create app support directory: %@", error.localizedDescription)
        }
        let dbPath = dir.appendingPathComponent("diagnostics.sqlite3").path
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            NSLog("DataStore: sqlite3_open failed for path %@: %@", dbPath, String(cString: sqlite3_errmsg(db)))
            db = nil
        } else {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        }
    }
}
