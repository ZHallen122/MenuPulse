import Foundation
import SQLite3

/// Persistent store for per-process memory samples and daily baselines.
///
/// Uses raw SQLite3 (no external dependencies). All database work runs on a
/// private serial queue so callers never block the main thread.
final class DataStore {

    private let queue = DispatchQueue(label: "com.mbdiag.datastore")
    private var db: OpaquePointer?

    init() {
        queue.async { [weak self] in
            self?.openDatabase()
            self?.createTablesIfNeeded()
        }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Inserts a row for every process in `processes` (INSERT OR IGNORE).
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
    func baseline(for bundleID: String) -> (avgMB: Double, p90MB: Double)? {
        var result: (Double, Double)?
        queue.sync {
            result = queryBaseline(for: bundleID)
        }
        return result
    }

    // MARK: - Private helpers

    private func openDatabase() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("MenuBarDiagnostic", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("diagnostics.sqlite3").path
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createTablesIfNeeded() {
        guard let db = db else { return }
        let memorySamples = """
            CREATE TABLE IF NOT EXISTS memory_samples (
                id INTEGER PRIMARY KEY,
                pid INTEGER,
                bundle_id TEXT,
                app_name TEXT,
                memory_mb REAL,
                sampled_at INTEGER
            );
            """
        let dailyBaselines = """
            CREATE TABLE IF NOT EXISTS daily_baselines (
                bundle_id TEXT,
                date TEXT,
                avg_mb REAL,
                p90_mb REAL,
                PRIMARY KEY (bundle_id, date)
            );
            """
        sqlite3_exec(db, memorySamples, nil, nil, nil)
        sqlite3_exec(db, dailyBaselines, nil, nil, nil)
    }

    private func insertSamples(_ processes: [MenuBarProcess]) {
        guard let db = db else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = "INSERT OR IGNORE INTO memory_samples (pid, bundle_id, app_name, memory_mb, sampled_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        for process in processes {
            let bundleID = process.bundleIdentifier ?? "unknown"
            let memMB = Double(process.memoryFootprintBytes) / 1_048_576.0
            sqlite3_bind_int(stmt, 1, process.pid)
            sqlite3_bind_text(stmt, 2, (bundleID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (process.name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, memMB)
            sqlite3_bind_int64(stmt, 5, now)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    private func deleteStaleSamples() {
        guard let db = db else { return }
        let cutoff = Int64(Date().timeIntervalSince1970) - 7 * 86400
        let sql = "DELETE FROM memory_samples WHERE sampled_at < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    private func rebuildBaselines() {
        guard let db = db else { return }
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
        guard sqlite3_prepare_v2(db, fetchSQL, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        // Group rows into [bundleID+date: [Double]]
        var groups: [(bundleID: String, date: String, values: [Double])] = []
        var current: (bundleID: String, date: String, values: [Double])?

        while sqlite3_step(stmt) == SQLITE_ROW {
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
        if let c = current {
            groups.append((bundleID: c.bundleID, date: c.date, values: c.values))
        }

        // Upsert computed baselines.
        let upsertSQL = "INSERT OR REPLACE INTO daily_baselines (bundle_id, date, avg_mb, p90_mb) VALUES (?, ?, ?, ?);"
        var uStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &uStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(uStmt) }

        for group in groups {
            let sorted = group.values.sorted()
            let avg = sorted.reduce(0, +) / Double(sorted.count)
            let p90Index = max(0, Int(Double(sorted.count - 1) * 0.9))
            let p90 = sorted[p90Index]
            sqlite3_bind_text(uStmt, 1, (group.bundleID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(uStmt, 2, (group.date as NSString).utf8String, -1, nil)
            sqlite3_bind_double(uStmt, 3, avg)
            sqlite3_bind_double(uStmt, 4, p90)
            sqlite3_step(uStmt)
            sqlite3_reset(uStmt)
        }
    }

    private func queryBaseline(for bundleID: String) -> (avgMB: Double, p90MB: Double)? {
        guard let db = db else { return nil }
        let sql = "SELECT avg_mb, p90_mb FROM daily_baselines WHERE bundle_id = ? ORDER BY date DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_double(stmt, 0), sqlite3_column_double(stmt, 1))
    }
}
