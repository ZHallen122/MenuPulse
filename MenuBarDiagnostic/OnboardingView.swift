import SwiftUI
import UserNotifications

struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "stethoscope")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
                .padding(.top, 8)

            Text("Welcome to Bouncer")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Bouncer quietly monitors your menu bar apps and alerts you when one starts using too much memory.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button("Allow Notifications & Get Started") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    DispatchQueue.main.async { onContinue() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(48)
        .frame(width: 440, height: 340)
    }
}
