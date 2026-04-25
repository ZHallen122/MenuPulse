import Foundation
import SQLite3

extension DataStore {

    func createTablesIfNeeded() {
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
                state TEXT NOT NULL DEFAULT 'learning_phase_1',
                version TEXT,
                learning_started_at INTEGER,
                last_seen_at INTEGER
            );
            """
        let alertEvents = """
            CREATE TABLE IF NOT EXISTS alert_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                peak_memory_mb REAL NOT NULL,
                user_action TEXT NOT NULL DEFAULT 'none',
                swap_correlated INTEGER NOT NULL DEFAULT 0
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
        if sqlite3_exec(db, alertEvents, nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: failed to create alert_events table: %@", String(cString: sqlite3_errmsg(db)))
        }
        migrateDailyBaselines()
        migrateAppLifecycle()
        migrateAlertEvents()
        closeOrphanedAlertEvents()
        purgeSelfAlertEvents()
    }

    /// Adds `version` and `state` columns to `daily_baselines` if they don't already exist.
    /// SQLite does not support `ADD COLUMN IF NOT EXISTS`, so we check `PRAGMA table_info` first.
    func migrateDailyBaselines() {
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

        if !existingColumns.contains("median_mb") {
            let sql = "ALTER TABLE daily_baselines ADD COLUMN median_mb REAL;"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("DataStore: failed to add 'median_mb' column to daily_baselines: %@",
                      String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Adds missing columns to `alert_events` for installs that had an older schema.
    func migrateAlertEvents() {
        guard let db = db else { return }
        var existingColumns = Set<String>()
        let pragmaSQL = "PRAGMA table_info(alert_events);"
        var pragmaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, pragmaSQL, -1, &pragmaStmt, nil) == SQLITE_OK {
            while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(pragmaStmt, 1) {
                    existingColumns.insert(String(cString: namePtr))
                }
            }
        }
        sqlite3_finalize(pragmaStmt)

        let additions: [(column: String, sql: String)] = [
            ("ended_at",        "ALTER TABLE alert_events ADD COLUMN ended_at INTEGER;"),
            ("peak_memory_mb",  "ALTER TABLE alert_events ADD COLUMN peak_memory_mb REAL NOT NULL DEFAULT 0;"),
            ("user_action",     "ALTER TABLE alert_events ADD COLUMN user_action TEXT NOT NULL DEFAULT 'none';"),
            ("swap_correlated", "ALTER TABLE alert_events ADD COLUMN swap_correlated INTEGER NOT NULL DEFAULT 0;"),
        ]
        for (column, sql) in additions where !existingColumns.contains(column) {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("DataStore: failed to add '%@' column to alert_events: %@",
                      column, String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Adds `sample_count` column to `app_lifecycle` if it doesn't already exist.
    func migrateAppLifecycle() {
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

        // Migrate legacy 'learning' default state to the current 'learning_phase_1'.
        // Rows inserted before the numbered-phase system was introduced carry the old
        // default. Treat them identically to phase_1 so they flow through the normal
        // phase advancement logic rather than hitting the stale/legacy branch.
        let migrateLearning = "UPDATE app_lifecycle SET state = 'learning_phase_1' WHERE state = 'learning';"
        if sqlite3_exec(db, migrateLearning, nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: failed to migrate legacy 'learning' state: %@",
                  String(String(cString: sqlite3_errmsg(db))))
        }
    }

    /// Closes any alert_events rows that were left open by a previous session (e.g. crash).
    /// Called once after the DB is fully set up. Orphaned rows would appear as "Still active"
    /// forever and inflate average-duration calculations.
    func closeOrphanedAlertEvents() {
        guard let db = db else { return }
        // Mark ended_at = started_at so duration = 0 rather than "infinity".
        let sql = "UPDATE alert_events SET ended_at = started_at, user_action = 'none' WHERE ended_at IS NULL;"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("DataStore: closeOrphanedAlertEvents failed: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Deletes any alert_events rows recorded for this app itself (rows written before the
    /// self-exclusion guard was added). Safe to call repeatedly — idempotent DELETE.
    func purgeSelfAlertEvents() {
        guard let db = db,
              let ownID = Bundle.main.bundleIdentifier else { return }
        let sql = "DELETE FROM alert_events WHERE bundle_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (ownID as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("DataStore: purgeSelfAlertEvents failed: %@", String(cString: sqlite3_errmsg(db)))
        }
    }
}
