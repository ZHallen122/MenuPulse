import SwiftUI
import AppKit

// MARK: - HistoryView

/// Standalone "History" window content.
///
/// Default view: Top Offenders leaderboard ranked by alert count.
/// Drill-down view: per-app timeline, opened by tapping any leaderboard row.
struct HistoryView: View {
    let dataStore: DataStore

    @State private var selectedDays: Int = 7
    @State private var leaderboard: [AlertLeaderboardEntry] = []
    @State private var selectedEntry: AlertLeaderboardEntry? = nil
    @State private var timeline: [AlertTimelineEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let entry = selectedEntry {
                timelineContent(for: entry)
            } else {
                leaderboardContent
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { loadLeaderboard() }
        .onChange(of: selectedDays) { _ in
            selectedEntry = nil
            timeline = []
            loadLeaderboard()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let entry = selectedEntry {
                Button(action: { selectedEntry = nil; timeline = [] }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Text(entry.appName)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("Top Offenders")
                    .font(.headline)
            }

            Spacer()

            Picker("", selection: $selectedDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Leaderboard

    private var leaderboardContent: some View {
        Group {
            if leaderboard.isEmpty {
                emptyLeaderboard
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        insightCard
                        Divider().padding(.vertical, 4)
                        ForEach(Array(leaderboard.enumerated()), id: \.element.id) { index, entry in
                            LeaderboardRowView(rank: index + 1, entry: entry) {
                                selectedEntry = entry
                                loadTimeline(for: entry)
                            }
                            if index < leaderboard.count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyLeaderboard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No alerts in the last \(selectedDays) days")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Bouncer will show your most frequent offenders here once alerts are triggered.")
                .font(.caption)
                .foregroundColor(Color.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var insightCard: some View {
        if let top = leaderboard.first {
            Text(insightText(for: top))
                .font(.callout)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
        }
    }

    private func insightText(for top: AlertLeaderboardEntry) -> String {
        let count = top.alertCount
        let period = selectedDays == 7 ? "this week" : "this month"
        var parts = ["\(top.appName) triggered \(count) alert\(count == 1 ? "" : "s") \(period)"]
        if let avg = top.avgDurationSec, avg >= 60 {
            let min = Int(avg / 60)
            parts.append("averaging \(min) minute\(min == 1 ? "" : "s") per event")
        }
        return parts.joined(separator: ", ") + ". Consider quitting \(top.appName) when not in use, or disabling it at login."
    }

    // MARK: - Timeline

    private func timelineContent(for entry: AlertLeaderboardEntry) -> some View {
        Group {
            if timeline.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No timeline events found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(timeline.enumerated()), id: \.element.id) { index, event in
                            TimelineRowView(entry: event)
                            if index < timeline.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data loading

    private func loadLeaderboard() {
        let days = selectedDays
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = dataStore.alertLeaderboard(days: days)
            DispatchQueue.main.async {
                self.leaderboard = rows
            }
        }
    }

    private func loadTimeline(for entry: AlertLeaderboardEntry) {
        let days = selectedDays
        let bundleID = entry.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = dataStore.alertTimeline(bundleID: bundleID, days: days)
            DispatchQueue.main.async {
                self.timeline = rows
            }
        }
    }
}

// MARK: - LeaderboardRowView

private struct LeaderboardRowView: View {
    let rank: Int
    let entry: AlertLeaderboardEntry
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var appIconImage: NSImage? = nil

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Rank badge
                Text("#\(rank)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .trailing)

                // App icon
                Group {
                    if let img = appIconImage {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 24, height: 24)

                // Name + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.appName)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Alert count + last seen
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(entry.alertCount) alert\(entry.alertCount == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(rank == 1 ? .orange : .secondary)
                    Text(relativeDate(entry.lastAlertAt))
                        .font(.caption2)
                        .foregroundColor(Color.secondary.opacity(0.8))
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovered ? Color.secondary.opacity(0.07) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .task(id: entry.bundleID) {
            let bundleID = entry.bundleID
            let img = await Task.detached(priority: .userInitiated) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil as NSImage? }
                return NSWorkspace.shared.icon(forFile: url.path)
            }.value
            appIconImage = img
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let avg = entry.avgDurationSec, avg >= 60 {
            let min = Int(avg / 60)
            parts.append("avg \(min)m/event")
        }
        var actions: [String] = []
        if entry.restartedCount > 0 { actions.append("Restarted \(entry.restartedCount)×") }
        if entry.quitCount > 0      { actions.append("Quit \(entry.quitCount)×") }
        if entry.ignoredCount > 0   { actions.append("Ignored \(entry.ignoredCount)×") }
        if !actions.isEmpty { parts.append(actions.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 120 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "Yesterday" : "\(days)d ago"
    }
}

// MARK: - TimelineRowView

private struct TimelineRowView: View {
    let entry: AlertTimelineEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Timestamp
                Text(Self.dateFormatter.string(from: entry.startedAt))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)

                Spacer()

                // Swap badge
                if entry.swapCorrelated {
                    Label("Swap active", systemImage: "internaldrive.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 16) {
                // Peak memory
                Label(String(format: "Peak %.0f MB", entry.peakMemoryMB), systemImage: "memorychip")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                // User action
                HStack(spacing: 4) {
                    Image(systemName: actionIcon)
                        .font(.caption2)
                        .foregroundColor(actionColor)
                    Text(actionLabel)
                        .font(.caption)
                        .foregroundColor(actionColor)
                }
            }

            // Duration / resolution
            if let dur = entry.durationSec {
                Text(resolutionLabel(dur))
                    .font(.caption2)
                    .foregroundColor(Color.secondary.opacity(0.8))
            } else {
                Text("Still active")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var actionLabel: String {
        switch entry.userAction {
        case "restarted": return "You restarted"
        case "quit":      return "You quit"
        case "ignored":   return "You ignored"
        default:          return "No action"
        }
    }

    private var actionIcon: String {
        switch entry.userAction {
        case "restarted": return "arrow.clockwise"
        case "quit":      return "xmark.circle"
        case "ignored":   return "bell.slash"
        default:          return "minus.circle"
        }
    }

    private var actionColor: Color {
        switch entry.userAction {
        case "restarted": return .green
        case "quit":      return .blue
        case "ignored":   return .secondary
        default:          return Color.secondary.opacity(0.6)
        }
    }

    private func resolutionLabel(_ sec: Double) -> String {
        let min = Int(sec / 60)
        if min < 1  { return "Resolved in under a minute" }
        if min < 60 { return "Resolved after \(min) min" }
        let hr = min / 60; let rem = min % 60
        return rem > 0 ? "Resolved after \(hr)h \(rem)m" : "Resolved after \(hr)h"
    }
}

// MARK: - Preview

#Preview {
    HistoryView(dataStore: DataStore(path: ":memory:"))
        .frame(width: 600, height: 500)
}
