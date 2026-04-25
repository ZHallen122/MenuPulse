import XCTest

final class DataStoreSamplesTests: BouncerTestCase {

    func testPersistSamplesAndRetrieve() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: "com.test.Store", memoryMB: 100)])
        Thread.sleep(forTimeInterval: 0.1)

        let samples = store.recentSamples(for: "com.test.Store", since: Date().addingTimeInterval(-3600))
        XCTAssertFalse(samples.isEmpty, "persisted sample should be retrievable")
        XCTAssertEqual(samples.first?.memoryMB ?? 0, 100, accuracy: 0.01)
    }

    func testRecentSamplesRespectsSinceCutoff() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        store.persistSamples([makeProcess(bundleID: "com.test.Since", memoryMB: 100)])
        Thread.sleep(forTimeInterval: 0.1)

        // Query with a cutoff 1 second after the insert — the sample was recorded before this
        let samples = store.recentSamples(for: "com.test.Since", since: Date().addingTimeInterval(1))
        XCTAssertTrue(samples.isEmpty,
                      "recentSamples(since:) must exclude samples with timestamps before the cutoff")
    }

    func testRecentSamplesEmptyForUnknownBundleID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let samples = store.recentSamples(for: "com.test.NeverInserted", since: Date().addingTimeInterval(-3600))
        XCTAssertTrue(samples.isEmpty, "recentSamples must return empty for a bundle ID with no persisted samples")
    }

    func testSampleCountIncrementsWithSuccessivePersists() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.SampleCount"

        // First persist tick: each call to persistSamples increments sample_count by 1
        // per unique bundle ID seen in that tick (see insertSamples seenBundleIDs logic).
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 11001)])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(store.sampleCount(for: bundleID), 1,
                       "sampleCount must be 1 after the first persistSamples call")

        // Second persist tick with a different pid → sample_count increments to 2
        store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: 100, pid: 11002)])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(store.sampleCount(for: bundleID), 2,
                       "sampleCount must be 2 after the second persistSamples call")
    }
}
