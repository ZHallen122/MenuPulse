# Bouncer

A native macOS menu bar app that watches other menu bar apps for memory anomalies and sends actionable alerts before they slow your system down.

---

## What it does

Bouncer sits in your menu bar as a stethoscope icon. It silently monitors the memory usage of every other menu bar app running on your Mac. When a process shows a sustained, upward memory trend that pushes into elevated system memory pressure, Bouncer notifies you — with a **Restart Now** or **Ignore** action — so you can act before the app causes a slowdown.

The icon color reflects current system memory pressure at a glance:

| Color | Meaning |
|---|---|
| Green | Normal |
| Orange | Warning |
| Red | Critical |

---

## Features

- **Three-condition anomaly detection** — An app is flagged only when all three are true simultaneously:
  1. Current memory > p90 baseline × sensitivity multiplier
  2. 30-minute upward trend (linear regression slope > 0)
  3. System memory pressure is Warning or Critical
- **3-day learning period** — Bouncer collects a baseline before it fires any alerts, avoiding false positives on freshly-installed apps.
- **Actionable notifications** — Each alert offers **Restart Now** (relaunches the offending app) or **Ignore**. A 24-hour per-app cooldown prevents repeat alerts for the same process.
- **10-minute persistence gate** — An app must remain anomalous for 10 continuous minutes before a notification fires.
- **Memory sparklines** — Click the status icon to open the popover and see rolling memory sparklines for every monitored app. Anomalous apps are highlighted in amber.
- **Settings** — Configure the ignore list, sensitivity (Low / Medium / High), and launch at login.

---

## Architecture

```
AppDelegate
├── NSStatusItem (stethoscope icon, green/orange/red tint)
└── NSPopover → StatusMenuView (SwiftUI)

ProcessMonitor  ──samples every 2s──►  AnomalyDetector
     │                                       │
     │  (accessory-policy processes)         │  evaluates 3 conditions
     ▼                                       ▼
 DataStore (SQLite)              UNUserNotificationCenter
   per-app memory samples          "Restart Now" / "Ignore"
   p90 baseline computation
```

### Data flow

1. `ProcessMonitor` samples all running accessory-policy apps every 2 seconds via `proc_pidinfo`, collecting resident memory (MB) for each.
2. Each sample is stored in `DataStore` (SQLite). The store computes the p90 baseline per bundle ID and prunes samples older than 3 days.
3. `AnomalyDetector` evaluates the three conditions on every sample tick and publishes `anomalousBundleIDs`.
4. After 10 continuous minutes of anomaly, `AnomalyDetector` posts a `UNUserNotification` for that app (subject to the 24-hour cooldown).
5. `AppDelegate` handles the notification response: **Restart Now** terminates and relaunches the app; **Ignore** dismisses.
6. `StatusMenuView` (in the popover) observes `ProcessMonitor` and `AnomalyDetector` and renders the process list with amber highlights for anomalous apps.

### Key files

| File | Role |
|---|---|
| `AppDelegate.swift` | App entry point; owns `NSStatusItem`, `NSPopover`, notification handling |
| `ProcessMonitor.swift` | Sampling engine; publishes `[MenuBarProcess]` and system memory pressure |
| `AnomalyDetector.swift` | Three-condition evaluator; posts notifications; owns anomaly timers and cooldowns |
| `DataStore.swift` | SQLite wrapper; stores per-app samples, computes p90 baseline |
| `MenuBarProcess.swift` | Immutable value-type snapshot of a single process |
| `StatusMenuView.swift` | SwiftUI popover root; shows process list with sparklines and anomaly highlights |
| `SparklineView.swift` | `Canvas`-based rolling memory sparkline |
| `PreferencesManager.swift` | `ObservableObject` wrapping `@AppStorage` user preferences |
| `SettingsView.swift` | SwiftUI settings UI (ignore list, sensitivity, launch at login) |

---

## Building and running

### Requirements

- macOS 13 Ventura or later
- Xcode 15+

### Steps

1. Clone the repository and open the project:
   ```bash
   git clone <repo-url>
   cd Menu-Bar-Diagnostic
   open "Menu Bar Diagnostic.xcodeproj"
   ```

2. Select the **Menu Bar Diagnostic** scheme and your Mac as the run destination.

3. Press **⌘R** to build and run.

> The app has no main window. After launch it appears only as a stethoscope icon in the menu bar.

### Command-line build

```bash
xcodebuild -project "Menu Bar Diagnostic.xcodeproj" \
           -scheme "Menu Bar Diagnostic" \
           -configuration Debug build
```

---

## Settings

| Setting | Description |
|---|---|
| Ignore list | Apps in this list are never monitored or alerted on |
| Sensitivity | Low / Medium / High — adjusts the p90 multiplier threshold |
| Launch at login | Registers/unregisters via `SMAppService` |

---

## License

MIT — see `LICENSE` for details.
