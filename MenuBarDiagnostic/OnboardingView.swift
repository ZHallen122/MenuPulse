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

            Text("Bouncer watches your menu bar apps for memory leaks and swap spikes.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button("Enable Notifications & Continue") {
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
