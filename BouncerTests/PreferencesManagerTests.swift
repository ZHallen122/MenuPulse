import XCTest

final class PreferencesManagerTests: BouncerTestCase {

    func testIgnoredBundleIDsParsingTrimsWhitespace() {
        let prefs = PreferencesManager()
        prefs.ignoredBundleIDsRaw = " com.a , com.b , , com.c "
        XCTAssertEqual(prefs.ignoredBundleIDs, ["com.a", "com.b", "com.c"],
                       "ignoredBundleIDs must split on comma, trim whitespace, and drop empty entries")
    }

    func testIgnoredBundleIDsSetterJoinsWithComma() {
        let prefs = PreferencesManager()
        prefs.ignoredBundleIDs = ["com.a", "com.b"]
        XCTAssertEqual(prefs.ignoredBundleIDsRaw, "com.a,com.b",
                       "ignoredBundleIDs setter must join entries with comma into ignoredBundleIDsRaw")
    }

    func testIsInLearningPeriodTrueAndFalse() {
        // Just launched — learning period must be active
        UserDefaults.standard.set(Date(), forKey: "firstLaunchDate")
        let prefsNew = PreferencesManager()
        XCTAssertTrue(prefsNew.isInLearningPeriod,
                      "isInLearningPeriod must be true when firstLaunchDate is now")

        // Launched 4 days ago — 3-day learning window has expired
        UserDefaults.standard.set(Date().addingTimeInterval(-4 * 86400), forKey: "firstLaunchDate")
        let prefsOld = PreferencesManager()
        XCTAssertFalse(prefsOld.isInLearningPeriod,
                       "isInLearningPeriod must be false when firstLaunchDate is 4 days ago")

        // Restore: push firstLaunchDate well outside learning period for other tests
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")
    }

    func testAutomaticUpdateChecksDefaultAndToggle() {
        UserDefaults.standard.removeObject(forKey: "automaticUpdateChecks")
        defer { UserDefaults.standard.removeObject(forKey: "automaticUpdateChecks") }

        let prefs = PreferencesManager()

        // Default must be true so Sparkle checks for updates automatically out of the box.
        XCTAssertTrue(prefs.automaticUpdateChecks,
                      "automaticUpdateChecks must default to true")

        // Toggling off must persist false to UserDefaults so the setting survives relaunches.
        prefs.automaticUpdateChecks = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "automaticUpdateChecks"),
                       "disabling automaticUpdateChecks must persist false to UserDefaults.standard")
    }
}
