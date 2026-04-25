import Foundation
import SQLite3

extension DataStore {

    func rebuildBaselines() {
        guard let db = db else { return }
        // avg/median/p90 are computed in Swift (SQLite lacks native percentile functions);
        // filtering and ordering are pushed to SQL so the in-memory math is O(1) index access.
        // Fetch all (bundle_id, date, memory_mb) rows from the last 7 days.
        let cutoff = Int64(Date().timeIntervalSince1970) - 7 * 86400
        let fetchSQL = """
            SELECT bundle_id,
                   date(sampled_at, 'unixepoch', 'localtime') AS day,
                   memory_mb
            FROM memory_samples
            WHERE sampled_at >= ?
            ORDER BY bundle_id, day, memory_mb;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, fetchSQL, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in rebuildBaselines (fetch): %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_bind_int64(stmt, 1, cutoff) != SQLITE_OK {
            NSLog("DataStore: bind failed in rebuildBaselines (fetch): %@", String(cString: sqlite3_errmsg(db)))
            return
        }

        // Group rows into [bundleID+date: [Double]]
        var groups: [(bundleID: String, date: String, values: [Double])] = []
        var current: (bundleID: String, date: String, values: [Double])?

        var frc: Int32
        repeat {
            frc = sqlite3_step(stmt)
            if frc == SQLITE_ROW {
                let bundleID = String(cString: sqlite3_column_text(stmt, 0))
                let date     = String(cString: sqlite3_column_text(stmt, 1))
                let memMB    = sqlite3_column_double(stmt, 2)
                if var c = current, c.bundleID == bundleID, c.date == date {
                    c.values.append(memMB)
                    current = c
                } else {
                    if let c = current {
                        groups.append((bundleID: c.bundleID, date: c.date, values: c.values))
                    }
                    current = (bundleID, date, [memMB])
                }
            }
        } while frc == SQLITE_ROW
        if frc != SQLITE_DONE {
            NSLog("DataStore: rebuildBaselines fetch failed (%d): %@", frc, String(cString: sqlite3_errmsg(db)))
        }
        if let c = current {
            groups.append((bundleID: c.bundleID, date: c.date, values: c.values))
        }

        // Upsert computed baselines.
        let upsertSQL = "INSERT OR REPLACE INTO daily_baselines (bundle_id, date, avg_mb, p90_mb, median_mb) VALUES (?, ?, ?, ?, ?);"
        var uStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &uStmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in rebuildBaselines (upsert): %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(uStmt) }

        if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: BEGIN IMMEDIATE failed in rebuildBaselines: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        for group in groups {
            let sorted = group.values.sorted()
            let avg = sorted.reduce(0, +) / Double(sorted.count)
            let p90Index = max(0, Int(Double(sorted.count - 1) * 0.9))
            let p90 = sorted[p90Index]
            let median: Double = sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            if sqlite3_bind_text(uStmt, 1, (group.bundleID as NSString).utf8String, -1, nil) != SQLITE_OK ||
               sqlite3_bind_text(uStmt, 2, (group.date as NSString).utf8String, -1, nil) != SQLITE_OK ||
               sqlite3_bind_double(uStmt, 3, avg) != SQLITE_OK ||
               sqlite3_bind_double(uStmt, 4, p90) != SQLITE_OK ||
               sqlite3_bind_double(uStmt, 5, median) != SQLITE_OK {
                NSLog("DataStore: bind failed in rebuildBaselines (upsert): %@", String(cString: sqlite3_errmsg(db)))
                sqlite3_reset(uStmt)
                sqlite3_clear_bindings(uStmt)
                continue
            }
            let urc = sqlite3_step(uStmt)
            if urc != SQLITE_DONE && urc != SQLITE_ROW {
                NSLog("DataStore: rebuildBaselines upsert failed (%d): %@", urc, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(uStmt)
        }
        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: COMMIT failed in rebuildBaselines: %@", String(cString: sqlite3_errmsg(db)))
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
    }

    func getBaselineStmt() -> OpaquePointer? {
        if let stmt = cachedBaselineStmt { return stmt }
        guard let db = db else { return nil }
        let sql = "SELECT avg_mb, median_mb, p90_mb FROM daily_baselines WHERE bundle_id = ? ORDER BY date DESC LIMIT 1;"
        if sqlite3_prepare_v2(db, sql, -1, &cachedBaselineStmt, nil) != SQLITE_OK {
            NSLog("DataStore: sqlite3_prepare_v2 failed for getBaselineStmt: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return cachedBaselineStmt
    }

    func queryBaseline(for bundleID: String) -> (avgMB: Double, medianMB: Double, p90MB: Double)? {
        guard let stmt = getBaselineStmt() else { return nil }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        if sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) != SQLITE_OK {
            return nil
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_double(stmt, 0), sqlite3_column_double(stmt, 1), sqlite3_column_double(stmt, 2))
    }

    // MARK: - Lifecycle private helpers

    func getAppStateStmt() -> OpaquePointer? {
        if let stmt = cachedAppStateStmt { return stmt }
        guard let db = db else { return nil }
        let sql = "SELECT state FROM app_lifecycle WHERE bundle_id = ?;"
        if sqlite3_prepare_v2(db, sql, -1, &cachedAppStateStmt, nil) != SQLITE_OK {
            NSLog("DataStore: sqlite3_prepare_v2 failed for getAppStateStmt: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return cachedAppStateStmt
    }

    func queryAppState(for bundleID: String) -> String {
        guard let stmt = getAppStateStmt() else { return "learning_phase_1" }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return "learning_phase_1" }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return "learning_phase_1" }
        guard let ptr = sqlite3_column_text(stmt, 0) else { return "learning_phase_1" }
        return String(cString: ptr)
    }

    func getLifecycleEntryStmt() -> OpaquePointer? {
        if let stmt = cachedLifecycleEntryStmt { return stmt }
        guard let db = db else { return nil }
        let sql = "SELECT state, version, learning_started_at FROM app_lifecycle WHERE bundle_id = ?;"
        if sqlite3_prepare_v2(db, sql, -1, &cachedLifecycleEntryStmt, nil) != SQLITE_OK {
            NSLog("DataStore: sqlite3_prepare_v2 failed for getLifecycleEntryStmt: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return cachedLifecycleEntryStmt
    }

    func queryLifecycleEntry(for bundleID: String) -> (state: String, version: String?, learningStartedAt: Date?)? {
        guard let stmt = getLifecycleEntryStmt() else { return nil }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let state = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "learning_phase_1"
        let version: String? = sqlite3_column_type(stmt, 1) != SQLITE_NULL
            ? sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            : nil
        let learningStartedAt: Date? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
            ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))
            : nil
        return (state, version, learningStartedAt)
    }

    /// Upserts last_seen_at and state. Does NOT touch learning_started_at on updates
    /// (preserving whatever the existing row has). For new row inserts, sets
    /// learning_started_at to now when state has the "learning_" prefix.
    func doUpdateAppLifecycle(bundleID: String, state: String, version: String?, lastSeen: Date) {
        guard let db = db else { return }
        let lastSeenTS = Int64(lastSeen.timeIntervalSince1970)
        let nowTS = Int64(Date().timeIntervalSince1970)
        // For fresh INSERT: supply learning_started_at=now when state has the "learning_" prefix.
        // ON CONFLICT UPDATE: skip learning_started_at so the existing value is preserved.
        let sql = """
            INSERT INTO app_lifecycle (bundle_id, state, version, learning_started_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(bundle_id) DO UPDATE SET
                state = excluded.state,
                version = COALESCE(excluded.version, version),
                last_seen_at = excluded.last_seen_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doUpdateAppLifecycle: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (state as NSString).utf8String, -1, nil)
        if let v = version {
            sqlite3_bind_text(stmt, 3, (v as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if state.hasPrefix("learning_") {
            sqlite3_bind_int64(stmt, 4, nowTS)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, lastSeenTS)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("DataStore: doUpdateAppLifecycle failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    func doMarkStaleApps(lastSeenCutoff: Date) {
        guard let db = db else { return }
        let cutoffTS = Int64(lastSeenCutoff.timeIntervalSince1970)
        let sql = "UPDATE app_lifecycle SET state = 'stale' WHERE last_seen_at < ? AND state NOT IN ('stale', 'ignored');"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doMarkStaleApps: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffTS)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("DataStore: doMarkStaleApps failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    func doMarkIgnored(bundleID: String) {
        guard let db = db else { return }
        let nowTS = Int64(Date().timeIntervalSince1970)
        let sql = """
            INSERT INTO app_lifecycle (bundle_id, state, version, learning_started_at, last_seen_at)
            VALUES (?, 'ignored', NULL, NULL, ?)
            ON CONFLICT(bundle_id) DO UPDATE SET
                state = 'ignored',
                last_seen_at = excluded.last_seen_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doMarkIgnored: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, nowTS)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("DataStore: doMarkIgnored failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    func doResetToLearning(bundleID: String, version: String?) {
        guard let db = db else { return }
        let nowTS = Int64(Date().timeIntervalSince1970)
        // Upsert: always overwrite state, learning_started_at, and last_seen_at.
        // Explicitly set sample_count = 0 so the minimum-sample guard correctly silences notifications
        // during the first 15 minutes of the new version or return from stale.
        let sql = """
            INSERT INTO app_lifecycle (bundle_id, state, version, learning_started_at, last_seen_at, sample_count)
            VALUES (?, 'learning_phase_1', ?, ?, ?, 0)
            ON CONFLICT(bundle_id) DO UPDATE SET
                state = 'learning_phase_1',
                version = COALESCE(excluded.version, version),
                learning_started_at = excluded.learning_started_at,
                last_seen_at = excluded.last_seen_at,
                sample_count = 0;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doResetToLearning: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        if let v = version {
            sqlite3_bind_text(stmt, 2, (v as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int64(stmt, 3, nowTS)
        sqlite3_bind_int64(stmt, 4, nowTS)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("DataStore: doResetToLearning failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }

        // Purge historical samples and baselines to prevent data pollution.
        // A version update or a stale return means the old memory profile is no longer valid.
        let delSamplesSQL = "DELETE FROM memory_samples WHERE bundle_id = ?;"
        var delSamplesStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSamplesSQL, -1, &delSamplesStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delSamplesStmt, 1, (bundleID as NSString).utf8String, -1, nil)
            let rc = sqlite3_step(delSamplesStmt)
            if rc != SQLITE_DONE {
                NSLog("DataStore: doResetToLearning delete-samples step failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_finalize(delSamplesStmt)
        }

        let delBaselinesSQL = "DELETE FROM daily_baselines WHERE bundle_id = ?;"
        var delBaselinesStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delBaselinesSQL, -1, &delBaselinesStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delBaselinesStmt, 1, (bundleID as NSString).utf8String, -1, nil)
            let rc = sqlite3_step(delBaselinesStmt)
            if rc != SQLITE_DONE {
                NSLog("DataStore: doResetToLearning delete-baselines step failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_finalize(delBaselinesStmt)
        }
    }

    func doIsInPerAppLearningPeriod(bundleID: String, duration: TimeInterval) -> Bool {
        guard let db = db else { return false }
        let sql = "SELECT state, learning_started_at FROM app_lifecycle WHERE bundle_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doIsInPerAppLearningPeriod: %@", String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return false }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return true } // unknown app defaults to learning
        let state = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "learning_phase_1"
        guard state.hasPrefix("learning_") else { return false }
        guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else { return true }
        let learningStartedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)))
        return Date().timeIntervalSince(learningStartedAt) < duration
    }
}
