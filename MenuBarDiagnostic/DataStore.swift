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

    /// Opens a SQLite database at an explicit path. Pass `":memory:"` for an
    /// in-memory database suitable for unit tests.
    init(path: String) {
        queue.async { [weak self] in
            var dbPtr: OpaquePointer?
            if sqlite3_open(path, &dbPtr) == SQLITE_OK {
                self?.db = dbPtr
            } else {
                NSLog("DataStore: sqlite3_open failed for path %@: %@", path, String(cString: sqlite3_errmsg(dbPtr)))
            }
            self?.createTablesIfNeeded()
        }
    }

    deinit {
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
    /// Defaults to `"learning"` if the app has no recorded entry.
    func appState(for bundleID: String) -> String {
        var result = "learning"
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

    // MARK: - Private helpers

    private func openDatabase() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("MenuBarDiagnostic", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("DataStore: failed to create app support directory: %@", error.localizedDescription)
        }
        let dbPath = dir.appendingPathComponent("diagnostics.sqlite3").path
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            NSLog("DataStore: sqlite3_open failed for path %@: %@", dbPath, String(cString: sqlite3_errmsg(db)))
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
        let appLifecycle = """
            CREATE TABLE IF NOT EXISTS app_lifecycle (
                bundle_id TEXT PRIMARY KEY,
                state TEXT NOT NULL DEFAULT 'learning',
                version TEXT,
                learning_started_at INTEGER,
                last_seen_at INTEGER
            );
            """
        if sqlite3_exec(db, memorySamples, nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: failed to create memory_samples table: %@", String(cString: sqlite3_errmsg(db)))
        }
        if sqlite3_exec(db, dailyBaselines, nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: failed to create daily_baselines table: %@", String(cString: sqlite3_errmsg(db)))
        }
        if sqlite3_exec(db, appLifecycle, nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: failed to create app_lifecycle table: %@", String(cString: sqlite3_errmsg(db)))
        }
        migrateDailyBaselines()
        migrateAppLifecycle()
    }

    /// Adds `version` and `state` columns to `daily_baselines` if they don't already exist.
    /// SQLite does not support `ADD COLUMN IF NOT EXISTS`, so we check `PRAGMA table_info` first.
    private func migrateDailyBaselines() {
        guard let db = db else { return }
        var existingColumns = Set<String>()
        let pragmaSQL = "PRAGMA table_info(daily_baselines);"
        var pragmaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, pragmaSQL, -1, &pragmaStmt, nil) == SQLITE_OK {
            while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(pragmaStmt, 1) {
                    existingColumns.insert(String(cString: namePtr))
                }
            }
        }
        sqlite3_finalize(pragmaStmt)

        if !existingColumns.contains("version") {
            let sql = "ALTER TABLE daily_baselines ADD COLUMN version TEXT;"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("DataStore: failed to add 'version' column to daily_baselines: %@",
                      String(cString: sqlite3_errmsg(db)))
            }
        }
        if !existingColumns.contains("state") {
            let sql = "ALTER TABLE daily_baselines ADD COLUMN state TEXT DEFAULT 'active';"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("DataStore: failed to add 'state' column to daily_baselines: %@",
                      String(cString: sqlite3_errmsg(db)))
            }
        }
        if !existingColumns.contains("median_mb") {
            let sql = "ALTER TABLE daily_baselines ADD COLUMN median_mb REAL;"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("DataStore: failed to add 'median_mb' column to daily_baselines: %@",
                      String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Adds `sample_count` column to `app_lifecycle` if it doesn't already exist.
    private func migrateAppLifecycle() {
        guard let db = db else { return }
        var existingColumns = Set<String>()
        let pragmaSQL = "PRAGMA table_info(app_lifecycle);"
        var pragmaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, pragmaSQL, -1, &pragmaStmt, nil) == SQLITE_OK {
            while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(pragmaStmt, 1) {
                    existingColumns.insert(String(cString: namePtr))
                }
            }
        }
        sqlite3_finalize(pragmaStmt)

        if !existingColumns.contains("sample_count") {
            let sql = "ALTER TABLE app_lifecycle ADD COLUMN sample_count INTEGER DEFAULT 0;"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("DataStore: failed to add 'sample_count' column to app_lifecycle: %@",
                      String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func insertSamples(_ processes: [MenuBarProcess]) {
        guard let db = db else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = "INSERT INTO memory_samples (pid, bundle_id, app_name, memory_mb, sampled_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in insertSamples: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(stmt) }

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
        for bundleID in seenBundleIDs {
            sqlite3_bind_text(countStmt, 1, (bundleID as NSString).utf8String, -1, nil)
            let crc = sqlite3_step(countStmt)
            if crc != SQLITE_DONE && crc != SQLITE_ROW {
                NSLog("DataStore: sample_count increment failed (%d): %@", crc, String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(countStmt)
        }
    }

    private func deleteStaleSamples() {
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
    }

    private func queryRecentSamples(for bundleID: String, since: Date) -> [(memoryMB: Double, timestamp: Date)] {
        guard let db = db else { return [] }
        let cutoff = Int64(since.timeIntervalSince1970)
        let sql = "SELECT memory_mb, sampled_at FROM memory_samples WHERE bundle_id = ? AND sampled_at >= ? ORDER BY sampled_at ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in queryRecentSamples: %@", String(cString: sqlite3_errmsg(db)))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) != SQLITE_OK ||
           sqlite3_bind_int64(stmt, 2, cutoff) != SQLITE_OK {
            NSLog("DataStore: bind failed in queryRecentSamples: %@", String(cString: sqlite3_errmsg(db)))
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

    private func queryBaseline(for bundleID: String) -> (avgMB: Double, medianMB: Double, p90MB: Double)? {
        guard let db = db else { return nil }
        let sql = "SELECT avg_mb, median_mb, p90_mb FROM daily_baselines WHERE bundle_id = ? ORDER BY date DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("DataStore: sqlite3_prepare_v2 failed in queryBaseline: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) != SQLITE_OK {
            NSLog("DataStore: bind failed in queryBaseline: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_double(stmt, 0), sqlite3_column_double(stmt, 1), sqlite3_column_double(stmt, 2))
    }

    private func querySampleCount(for bundleID: String) -> Int {
        guard let db = db else { return 0 }
        let sql = "SELECT sample_count FROM app_lifecycle WHERE bundle_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Lifecycle private helpers

    private func queryAppState(for bundleID: String) -> String {
        guard let db = db else { return "learning" }
        let sql = "SELECT state FROM app_lifecycle WHERE bundle_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "learning" }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return "learning" }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return "learning" }
        guard let ptr = sqlite3_column_text(stmt, 0) else { return "learning" }
        return String(cString: ptr)
    }

    private func queryLifecycleEntry(for bundleID: String) -> (state: String, version: String?, learningStartedAt: Date?)? {
        guard let db = db else { return nil }
        let sql = "SELECT state, version, learning_started_at FROM app_lifecycle WHERE bundle_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let state = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "learning"
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
    /// learning_started_at to now when state == "learning".
    private func doUpdateAppLifecycle(bundleID: String, state: String, version: String?, lastSeen: Date) {
        guard let db = db else { return }
        let lastSeenTS = Int64(lastSeen.timeIntervalSince1970)
        let nowTS = Int64(Date().timeIntervalSince1970)
        // For fresh INSERT: supply learning_started_at=now when state=='learning'.
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

    private func doMarkStaleApps(lastSeenCutoff: Date) {
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

    private func doMarkIgnored(bundleID: String) {
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

    private func doResetToLearning(bundleID: String, version: String?) {
        guard let db = db else { return }
        let nowTS = Int64(Date().timeIntervalSince1970)
        // Upsert: always overwrite state, learning_started_at, and last_seen_at.
        let sql = """
            INSERT INTO app_lifecycle (bundle_id, state, version, learning_started_at, last_seen_at)
            VALUES (?, 'learning_phase_1', ?, ?, ?)
            ON CONFLICT(bundle_id) DO UPDATE SET
                state = 'learning_phase_1',
                version = COALESCE(excluded.version, version),
                learning_started_at = excluded.learning_started_at,
                last_seen_at = excluded.last_seen_at;
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
    }

    private func doIsInPerAppLearningPeriod(bundleID: String, duration: TimeInterval) -> Bool {
        guard let db = db else { return false }
        let sql = "SELECT state, learning_started_at FROM app_lifecycle WHERE bundle_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
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
