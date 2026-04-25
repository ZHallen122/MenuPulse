import XCTest

final class DataStoreAlertEventsTests: BouncerTestCase {

    func testInsertAlertEventReturnsValidRowID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let rowID = store.insertAlertEvent(
            bundleID: "com.test.AlertInsert",
            appName: "InsertApp",
            startedAt: Date(),
            peakMemoryMB: 150,
            swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(rowID, 1, "insertAlertEvent must return a row ID >= 1")
    }

    func testCloseAlertEventSetsEndedAtAndUserAction() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.AlertClose"
        let rowID = store.insertAlertEvent(
            bundleID: bundleID,
            appName: "CloseApp",
            startedAt: Date(),
            peakMemoryMB: 200,
            swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(rowID, 1)

        store.closeAlertEvent(id: rowID, endedAt: Date(), userAction: "restarted")
        Thread.sleep(forTimeInterval: 0.1)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(timeline.count, 1, "timeline must contain the closed event")
        XCTAssertNotNil(timeline.first?.endedAt, "endedAt must be set after closeAlertEvent")
        XCTAssertEqual(timeline.first?.userAction, "restarted",
                       "userAction must be 'restarted' after closeAlertEvent")
    }

    func testUpdateAlertEventPeakMAXSemantics() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.PeakMax"
        let rowID = store.insertAlertEvent(
            bundleID: bundleID,
            appName: "PeakApp",
            startedAt: Date(),
            peakMemoryMB: 100,
            swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(rowID, 1)

        // Update to a higher value — should grow
        store.updateAlertEventPeak(id: rowID, peakMemoryMB: 200)
        Thread.sleep(forTimeInterval: 0.1)

        let after200 = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(after200.first?.peakMemoryMB ?? 0, 200, accuracy: 0.01,
                       "peak must grow to 200 MB after updating with a higher value")

        // Update to a lower value — MAX semantics must prevent shrinkage
        store.updateAlertEventPeak(id: rowID, peakMemoryMB: 50)
        Thread.sleep(forTimeInterval: 0.1)

        let after50 = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(after50.first?.peakMemoryMB ?? 0, 200, accuracy: 0.01,
                       "peak must remain 200 MB after updateAlertEventPeak with a lower value (MAX semantics)")
    }

    func testAlertLeaderboardAggregatesCorrectly() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Leaderboard"
        let now = Date()

        let id1 = store.insertAlertEvent(
            bundleID: bundleID, appName: "LBApp",
            startedAt: now.addingTimeInterval(-120), peakMemoryMB: 300, swapCorrelated: false
        )
        let id2 = store.insertAlertEvent(
            bundleID: bundleID, appName: "LBApp",
            startedAt: now.addingTimeInterval(-60), peakMemoryMB: 350, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(id1, 1)
        XCTAssertGreaterThanOrEqual(id2, 1)

        store.closeAlertEvent(id: id1, endedAt: now.addingTimeInterval(-90), userAction: "restarted")
        store.closeAlertEvent(id: id2, endedAt: now.addingTimeInterval(-30), userAction: "quit")
        Thread.sleep(forTimeInterval: 0.1)

        let leaderboard = store.alertLeaderboard(days: 7)
        let entry = leaderboard.first { $0.bundleID == bundleID }
        XCTAssertNotNil(entry, "leaderboard must contain an entry for the test bundle ID")
        XCTAssertEqual(entry?.alertCount, 2, "alertCount must be 2 for two inserted events")
        XCTAssertEqual(entry?.restartedCount, 1, "restartedCount must be 1")
        XCTAssertEqual(entry?.quitCount, 1, "quitCount must be 1")
    }

    func testAlertTimelineNewestFirst() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.Timeline"
        let now = Date()

        // Insert older event first, then newer event
        let olderID = store.insertAlertEvent(
            bundleID: bundleID, appName: "TimeApp",
            startedAt: now.addingTimeInterval(-200), peakMemoryMB: 100, swapCorrelated: false
        )
        let newerID = store.insertAlertEvent(
            bundleID: bundleID, appName: "TimeApp",
            startedAt: now.addingTimeInterval(-100), peakMemoryMB: 200, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(olderID, 1)
        XCTAssertGreaterThanOrEqual(newerID, 1)

        store.closeAlertEvent(id: olderID, endedAt: now.addingTimeInterval(-150), userAction: "none")
        store.closeAlertEvent(id: newerID, endedAt: now.addingTimeInterval(-50), userAction: "none")
        Thread.sleep(forTimeInterval: 0.1)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(timeline.count, 2, "timeline must contain both inserted events")
        XCTAssertGreaterThan(
            timeline[0].startedAt.timeIntervalSince1970,
            timeline[1].startedAt.timeIntervalSince1970,
            "alertTimeline must return entries newest-first (higher startedAt first)"
        )
    }

    func testMarkIgnoredSurvivesMarkStaleApps() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.IgnoredStale"

        store.markIgnored(bundleID: bundleID)
        Thread.sleep(forTimeInterval: 0.1)

        // Use a cutoff 1 second in the future so last_seen_at < cutoff is true,
        // which would normally flip the state to "stale". Ignored is a terminal state
        // and must be preserved by the NOT IN ('stale', 'ignored') guard.
        store.markStaleApps(lastSeenCutoff: Date().addingTimeInterval(1))
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(store.appState(for: bundleID), "ignored",
                       "ignored state must survive markStaleApps — it is a terminal state")
    }

    func testAlertTimelineEmptyForUnknownBundleID() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let timeline = store.alertTimeline(bundleID: "com.test.NeverInserted", days: 7)
        XCTAssertTrue(timeline.isEmpty,
                      "alertTimeline must return empty for a bundle ID with no alert events")
    }

    func testAlertTimelineDayFilter() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.TimelineFilter"
        let now = Date()

        // Event 10 days ago — outside the 7-day window
        let oldID = store.insertAlertEvent(
            bundleID: bundleID, appName: "FilterApp",
            startedAt: now.addingTimeInterval(-10 * 86400),
            peakMemoryMB: 200, swapCorrelated: false
        )
        // Event 3 days ago — inside the 7-day window
        let recentID = store.insertAlertEvent(
            bundleID: bundleID, appName: "FilterApp",
            startedAt: now.addingTimeInterval(-3 * 86400),
            peakMemoryMB: 300, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(oldID, 1)
        XCTAssertGreaterThanOrEqual(recentID, 1)

        store.closeAlertEvent(id: oldID, endedAt: now.addingTimeInterval(-10 * 86400 + 3600), userAction: "none")
        store.closeAlertEvent(id: recentID, endedAt: now.addingTimeInterval(-3 * 86400 + 3600), userAction: "none")
        Thread.sleep(forTimeInterval: 0.1)

        let timeline = store.alertTimeline(bundleID: bundleID, days: 7)
        XCTAssertEqual(timeline.count, 1,
                       "alertTimeline(days: 7) must exclude events older than 7 days")
        XCTAssertEqual(timeline.first?.peakMemoryMB ?? 0, 300, accuracy: 0.01,
                       "the remaining event must be the 3-day-old one, not the 10-day-old one")
    }

    func testAlertLeaderboardDayFilter() {
        let store = DataStore(path: ":memory:")
        Thread.sleep(forTimeInterval: 0.1)

        let bundleID = "com.test.LeaderboardFilter"
        let now = Date()

        // Event 10 days ago — outside 7-day window
        let oldID = store.insertAlertEvent(
            bundleID: bundleID, appName: "LBFilterApp",
            startedAt: now.addingTimeInterval(-10 * 86400),
            peakMemoryMB: 200, swapCorrelated: false
        )
        // Event 2 days ago — inside 7-day window
        let recentID = store.insertAlertEvent(
            bundleID: bundleID, appName: "LBFilterApp",
            startedAt: now.addingTimeInterval(-2 * 86400),
            peakMemoryMB: 300, swapCorrelated: false
        )
        XCTAssertGreaterThanOrEqual(oldID, 1)
        XCTAssertGreaterThanOrEqual(recentID, 1)

        store.closeAlertEvent(id: oldID, endedAt: now.addingTimeInterval(-10 * 86400 + 3600), userAction: "none")
        store.closeAlertEvent(id: recentID, endedAt: now.addingTimeInterval(-2 * 86400 + 3600), userAction: "none")
        Thread.sleep(forTimeInterval: 0.1)

        let leaderboard = store.alertLeaderboard(days: 7)
        let entry = leaderboard.first { $0.bundleID == bundleID }
        XCTAssertNotNil(entry, "leaderboard must contain an entry for the test bundle ID")
        XCTAssertEqual(entry?.alertCount, 1,
                       "alertLeaderboard(days: 7) must count only the event within the last 7 days")
    }
}
