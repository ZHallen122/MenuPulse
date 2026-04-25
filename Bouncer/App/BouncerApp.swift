import SwiftUI

@main
struct BouncerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows — menu bar agent only
        Settings {
            SettingsView(
                prefs: appDelegate.prefs,
                anomalyDetector: appDelegate.anomalyDetector,
                onCheckForUpdates: { appDelegate.sparkleUpdater.checkForUpdates() }
            )
        }
    }
}
