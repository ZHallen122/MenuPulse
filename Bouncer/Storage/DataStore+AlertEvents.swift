import Foundation
import SQLite3

extension DataStore {

    func doInsertAlertEvent(
        bundleID: String, appName: String,
        startedAt: Date, peakMemoryMB: Double,
        swapCorrelated: Bool
    ) -> Int64 {
        guard let db = db else { return -1 }
        let sql = """
            INSERT INTO alert_events (bundle_id, app_name, started_at, peak_memory_mb, swap_correlated)
            VALUES (?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doInsertAlertEvent: %@", String(cString: sqlite3_errmsg(db)))
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (appName as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 3, Int64(startedAt.timeIntervalSince1970))
        sqlite3_bind_double(stmt, 4, peakMemoryMB)
        sqlite3_bind_int(stmt, 5, swapCorrelated ? 1 : 0)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            NSLog("DataStore: doInsertAlertEvent sqlite3_step failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    func doUpdateAlertEventPeak(id: Int64, peakMemoryMB: Double) {
        guard let db = db else { return }
        let sql = "UPDATE alert_events SET peak_memory_mb = MAX(peak_memory_mb, ?) WHERE id = ? AND ended_at IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doUpdateAlertEventPeak: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, peakMemoryMB)
        sqlite3_bind_int64(stmt, 2, id)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            NSLog("DataStore: doUpdateAlertEventPeak sqlite3_step failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    func doCloseAlertEvent(id: Int64, endedAt: Date, userAction: String) {
        guard let db = db else { return }
        let sql = "UPDATE alert_events SET ended_at = ?, user_action = ? WHERE id = ? AND ended_at IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in doCloseAlertEvent: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(endedAt.timeIntervalSince1970))
        sqlite3_bind_text(stmt, 2, (userAction as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 3, id)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("DataStore: doCloseAlertEvent failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    func queryAlertLeaderboard(days: Int) -> [AlertLeaderboardEntry] {
        guard let db = db else { return [] }
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(days) * 86400
        let sql = """
            SELECT
                bundle_id,
                MAX(app_name) AS app_name,
                COUNT(*) AS alert_count,
                AVG(CASE WHEN ended_at IS NOT NULL THEN CAST(ended_at - started_at AS REAL) ELSE NULL END) AS avg_duration_sec,
                MAX(started_at) AS last_alert_at,
                SUM(CASE WHEN user_action = 'restarted' THEN 1 ELSE 0 END) AS restarted_count,
                SUM(CASE WHEN user_action = 'quit'      THEN 1 ELSE 0 END) AS quit_count,
                SUM(CASE WHEN user_action = 'ignored'   THEN 1 ELSE 0 END) AS ignored_count
            FROM alert_events
            WHERE started_at >= ? AND bundle_id != COALESCE(?, '')
            GROUP BY bundle_id
            ORDER BY alert_count DESC, last_alert_at DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in queryAlertLeaderboard: %@", String(cString: sqlite3_errmsg(db)))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        let ownID = Bundle.main.bundleIdentifier ?? ""
        sqlite3_bind_text(stmt, 2, (ownID as NSString).utf8String, -1, nil)

        var rows: [AlertLeaderboardEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bundleID  = String(cString: sqlite3_column_text(stmt, 0))
            let appName   = String(cString: sqlite3_column_text(stmt, 1))
            let count     = Int(sqlite3_column_int(stmt, 2))
            let avgDur: Double? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
                ? sqlite3_column_double(stmt, 3) : nil
            let lastTS    = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)))
            let restarted = Int(sqlite3_column_int(stmt, 5))
            let quit      = Int(sqlite3_column_int(stmt, 6))
            let ignored   = Int(sqlite3_column_int(stmt, 7))
            rows.append(AlertLeaderboardEntry(
                bundleID: bundleID, appName: appName,
                alertCount: count, avgDurationSec: avgDur,
                lastAlertAt: lastTS,
                restartedCount: restarted, quitCount: quit, ignoredCount: ignored
            ))
        }
        return rows
    }

    func queryAlertTimeline(bundleID: String, days: Int) -> [AlertTimelineEntry] {
        guard let db = db else { return [] }
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(days) * 86400
        let sql = """
            SELECT id, started_at, ended_at, peak_memory_mb, user_action, swap_correlated
            FROM alert_events
            WHERE bundle_id = ? AND started_at >= ?
            ORDER BY started_at DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: prepare failed in queryAlertTimeline: %@", String(cString: sqlite3_errmsg(db)))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, cutoff)

        var rows: [AlertTimelineEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id       = sqlite3_column_int64(stmt, 0)
            let startedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)))
            let endedAt: Date? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2))) : nil
            let peakMB   = sqlite3_column_double(stmt, 3)
            let action   = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "none"
            let swapCor  = sqlite3_column_int(stmt, 5) != 0
            rows.append(AlertTimelineEntry(
                id: id, startedAt: startedAt, endedAt: endedAt,
                peakMemoryMB: peakMB, userAction: action, swapCorrelated: swapCor
            ))
        }
        return rows
    }
}
