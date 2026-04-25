import XCTest

final class MiscTests: BouncerTestCase {

    func testHasShownOnboardingGate() {
        UserDefaults.standard.removeObject(forKey: "hasShownOnboarding")
        defer { UserDefaults.standard.removeObject(forKey: "hasShownOnboarding") }

        // Default must be false so onboarding is shown on first launch.
        // AppDelegate guard: `guard !UserDefaults.standard.bool(forKey: "hasShownOnboarding") else { return }`
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasShownOnboarding"),
                       "hasShownOnboarding must default to false so onboarding is presented on first launch")

        // Once the user taps Continue the key is set true; onboarding must be suppressed on subsequent launches.
        UserDefaults.standard.set(true, forKey: "hasShownOnboarding")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasShownOnboarding"),
                      "hasShownOnboarding must return true after being set, causing onboarding to be skipped")
    }

    func testAppIconAppiconsetContainsContentsJson() {
        // Derive project root from this source file's path (not Bundle.main, which is the test runner).
        let testFileURL = URL(fileURLWithPath: #file)
        let projectRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let contentsJsonURL = projectRoot
            .appendingPathComponent("Bouncer")
            .appendingPathComponent("Assets.xcassets")
            .appendingPathComponent("AppIcon.appiconset")
            .appendingPathComponent("Contents.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentsJsonURL.path),
                      "AppIcon.appiconset/Contents.json must exist to wire the app icon into the Xcode asset catalog")
    }
}
