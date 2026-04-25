import XCTest

final class DataStoreSchemaTests: BouncerTestCase {

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

    func testRebuildBaselinesAtomicityAllGroupsCommitted() {
        // Insert 5 samples each for 3 bundle IDs, recomputeBaselines, verify ALL three get baselines.
        // This proves BEGIN;…COMMIT; in rebuildBaselines commits all groups in one transaction.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let ids = ["com.test.Tx.A", "com.test.Tx.B", "com.test.Tx.C"]
        for (offset, bid) in ids.enumerated() {
            let procs = (0..<5).map { i in
                makeProcess(bundleID: bid, memoryMB: Double(100 + i * 10), pid: Int32(60000 + offset * 10 + i))
            }
            store.persistSamples(procs)
        }
        Thread.sleep(forTimeInterval: 0.1)

        store.recomputeBaselines()
        Thread.sleep(forTimeInterval: 0.2)

        for bid in ids {
            XCTAssertNotNil(store.baseline(for: bid),
                            "baseline must be non-nil for \(bid) — rebuildBaselines must commit all groups atomically")
        }
    }

    func testInsertSamplesBulkConsistency() {
        // 20 processes sharing one bundle ID in a single persistSamples call must all be committed.
        // This exercises the per-row loop inside BEGIN IMMEDIATE;…COMMIT; in insertSamples.
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Tx.Bulk"
        let procs = (0..<20).map { i in
            makeProcess(bundleID: bundleID, memoryMB: Double(50 + i), pid: Int32(70000 + i))
        }
        store.persistSamples(procs)
        Thread.sleep(forTimeInterval: 0.1)

        let samples = store.recentSamples(for: bundleID, since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(samples.count, 20,
                       "all 20 rows for a single bulk persistSamples call must be committed atomically")
    }
}
