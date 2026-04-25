import Foundation
import SQLite3

extension DataStore {

    func insertSamples(_ processes: [MenuBarProcess]) {
        guard let db = db else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = "INSERT INTO memory_samples (pid, bundle_id, app_name, memory_mb, sampled_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in insertSamples: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }

        // Increment sample_count for each unique bundle ID seen this tick.
        let countSQL = """
            INSERT INTO app_lifecycle (bundle_id, sample_count) VALUES (?, 1)
            ON CONFLICT(bundle_id) DO UPDATE SET sample_count = sample_count + 1;
            """
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in insertSamples (count): %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(countStmt) }

        if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: BEGIN IMMEDIATE failed in insertSamples: %@", String(cString: sqlite3_errmsg(db)))
            return
        }

        var seenBundleIDs = Set<String>()
        for process in processes {
            let bundleID = process.bundleIdentifier ?? "unknown"
            let memMB = Double(process.memoryFootprintBytes) / 1_048_576.0
            if sqlite3_bind_int(stmt, 1, process.pid) != SQLITE_OK ||
               sqlite3_bind_text(stmt, 2, (bundleID as NSString).utf8String, -1, nil) != SQLITE_OK ||
               sqlite3_bind_text(stmt, 3, (process.name as NSString).utf8String, -1, nil) != SQLITE_OK ||
               sqlite3_bind_double(stmt, 4, memMB) != SQLITE_OK ||
               sqlite3_bind_int64(stmt, 5, now) != SQLITE_OK {
                NSLog("DataStore: bind failed in insertSamples: %@", String(cString: sqlite3_errmsg(db)))
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                continue
            }
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                NSLog("DataStore: insertSamples sqlite3_step failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
            seenBundleIDs.insert(bundleID)
        }

        for bundleID in seenBundleIDs {
            sqlite3_bind_text(countStmt, 1, (bundleID as NSString).utf8String, -1, nil)
            let crc = sqlite3_step(countStmt)
            if crc != SQLITE_DONE && crc != SQLITE_ROW {
                NSLog("DataStore: sample_count increment failed (%d): %@", crc, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(countStmt)
        }

        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: COMMIT failed in insertSamples: %@", String(cString: sqlite3_errmsg(db)))
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
    }

    func deleteStaleSamples() {
        guard let db = db else { return }
        let cutoff = Int64(Date().timeIntervalSince1970) - 7 * 86400
        let sql = "DELETE FROM memory_samples WHERE sampled_at < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in deleteStaleSamples: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_bind_int64(stmt, 1, cutoff) != SQLITE_OK {
            NSLog("DataStore: bind failed in deleteStaleSamples: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("DataStore: deleteStaleSamples sqlite3_step failed (%d): %@", rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    func getRecentSamplesStmt() -> OpaquePointer? {
        if let stmt = cachedRecentSamplesStmt { return stmt }
        guard let db = db else { return nil }
        let sql = "SELECT memory_mb, sampled_at FROM memory_samples WHERE bundle_id = ? AND sampled_at >= ? ORDER BY sampled_at ASC;"
        if sqlite3_prepare_v2(db, sql, -1, &cachedRecentSamplesStmt, nil) != SQLITE_OK {
            NSLog("DataStore: sqlite3_prepare_v2 failed for getRecentSamplesStmt: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return cachedRecentSamplesStmt
    }

    func queryRecentSamples(for bundleID: String, since: Date) -> [(memoryMB: Double, timestamp: Date)] {
        guard let stmt = getRecentSamplesStmt() else { return [] }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        let cutoff = Int64(since.timeIntervalSince1970)
        if sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) != SQLITE_OK ||
           sqlite3_bind_int64(stmt, 2, cutoff) != SQLITE_OK {
            return []
        }
        var rows: [(memoryMB: Double, timestamp: Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let memMB = sqlite3_column_double(stmt, 0)
            let ts = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)))
            rows.append((memoryMB: memMB, timestamp: ts))
        }
        return rows
    }

    func getSampleCountStmt() -> OpaquePointer? {
        if let stmt = cachedSampleCountStmt { return stmt }
        guard let db = db else { return nil }
        let sql = "SELECT sample_count FROM app_lifecycle WHERE bundle_id = ?;"
        if sqlite3_prepare_v2(db, sql, -1, &cachedSampleCountStmt, nil) != SQLITE_OK {
            NSLog("DataStore: sqlite3_prepare_v2 failed for getSampleCountStmt: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return cachedSampleCountStmt
    }

    func querySampleCount(for bundleID: String) -> Int {
        guard let stmt = getSampleCountStmt() else { return 0 }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
