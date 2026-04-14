# Bouncer

A native macOS menu bar app that watches other menu bar apps for memory anomalies and sends actionable alerts before they slow your system down.

<img width="328" height="452" alt="image" src="https://github.com/user-attachments/assets/68212162-10c2-4301-a77a-25af2b9bdc08" />


<img width="573" height="455" alt="image" src="https://github.com/user-attachments/assets/eb7e5f4a-3449-41cd-9f0a-c8110666567a" />



---

## What it does

Bouncer sits in your menu bar as a stethoscope-themed app icon (AppIcon.appiconset). It silently monitors the memory usage of every other menu bar app running on your Mac. When a process shows a sustained, upward memory trend that pushes into elevated system memory pressure, Bouncer notifies you — with a **Restart Now** or **Ignore** action — so you can act before the app causes a slowdown.

The icon color reflects current system state at a glance:

| Color | Meaning |
|---|---|
| Green | All clear (no swap, no anomalies) |
| Yellow | Memory anomaly detected |
| Orange | Swap memory in use |
| Red | Swap memory growing rapidly |

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
- **Swap memory detection** — `SwapMonitor` polls `vm.swapusage` every 30 seconds. When swap transitions from inactive to active, Bouncer sends a notification with **Quit Top App** / **View All** / **Dismiss** actions (1-hour cooldown). The icon turns orange while swap is in use, and red when swap is growing rapidly (> ~10 MB/min).
- **Settings** — Configure sensitivity (Low / Medium / High), launch at login, and a dedicated Block List tab for managing ignored bundle IDs via a list UI with `+` / `-` controls.
- **First-launch onboarding** — On first run a welcome sheet explains what Bouncer does and requests notification permission. Shown once, gated by `hasShownOnboarding`.
- **Automatic updates** — Sparkle 2.9.1 checks for updates in the background. A "Check for Updates" button is available in Settings, and automatic checks can be toggled on/off.

---

## Architecture

```
MenuBarDiagnosticApp (@main, SwiftUI App)
└── AppDelegate (via @NSApplicationDelegateAdaptor)
    ├── NSStatusItem (stethoscope icon, green/orange/red tint)
    └── NSPopover → HUDView (SwiftUI)

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
| `MenuBarDiagnosticApp.swift` | SwiftUI `@main` entry point; wires `AppDelegate` via `@NSApplicationDelegateAdaptor` |
| `AppDelegate.swift` | Owns `NSStatusItem`, `NSPopover`, notification handling |
| `ProcessMonitor.swift` | Sampling engine; publishes `[MenuBarProcess]` and system memory pressure |
| `AnomalyDetector.swift` | Three-condition evaluator; posts notifications; owns anomaly timers and cooldowns |
| `DataStore.swift` | SQLite wrapper; stores per-app samples, computes p90 baseline |
| `MenuBarProcess.swift` | Immutable value-type snapshot of a single process |
| `StatusMenuView.swift` | SwiftUI popover root; shows process list with sparklines and anomaly highlights |
| `HUDView.swift` | Main popover HUD listing all monitored processes |
| `HUDWindow.swift` | `NSWindow` subclass that hosts the HUD |
| `HUDProcessRow.swift` | Single process row with alert-threshold highlighting |
| `ThermalHeaderView.swift` | Header showing system thermal/memory pressure state |
| `RAMBarView.swift` | Visual RAM usage bar component |
| `MemoryPressure.swift` | System memory pressure reading utilities |
| `ProcessDetailSheet.swift` | Expanded detail sheet for a single process |
| `ThermalState+Display.swift` | Extension adding display strings to `ProcessInfo.ThermalState` |
| `IconColorLogic.swift` | Pure `iconColor()` function; maps `SwapState` + `pendingAnomalyAlert` → `NSColor` for the status bar icon |
| `SwapMonitor.swift` | `ObservableObject` that polls `vm.swapusage` every 30 s; publishes swap stats and `SwapState`; posts swap-active notification |
| `SparklineView.swift` | `Canvas`-based rolling memory sparkline |
| `HistoryView.swift` | History window SwiftUI view; top-offenders leaderboard and per-app memory timeline |
| `HistoryWindow.swift` | `NSWindow` subclass that hosts the history view |
| `PreferencesManager.swift` | `ObservableObject` wrapping `@AppStorage` user preferences |
| `SettingsView.swift` | SwiftUI settings UI (sensitivity, launch at login, Block List tab for ignored bundle IDs) |
| `OnboardingView.swift` | First-launch onboarding sheet; requests notification permission; gated by `hasShownOnboarding` UserDefaults key |
| `SparkleUpdater.swift` | Sparkle 2.9.1 wrapper; drives automatic and manual update checks |

---

## Building and running

### Requirements

- macOS 13 Ventura or later
- Xcode 15+

### Steps

1. Clone the repository and open the project:
   ```bash
   git clone https://github.com/ZHallen122/MenuPulse
   cd MenuPulse
   open "Menu Bar Diagnostic.xcodeproj"
   ```

2. Select the **Menu Bar Diagnostic** scheme and your Mac as the run destination.

3. Press **⌘R** to build and run.

> The app has no main window. After launch it appears only as a stethoscope icon in the menu bar.

### Command-line build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Menu Bar Diagnostic.xcodeproj" \
           -scheme "Menu Bar Diagnostic" \
           -configuration Debug build
```

### Running tests

The main scheme is not configured for testing. Use the dedicated test scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Menu Bar Diagnostic.xcodeproj" \
           -scheme "MenuBarDiagnosticTests" \
           -configuration Debug test
```

---

## Settings

| Setting | Description |
|---|---|
| Block List | Apps in this list are never monitored or alerted on; managed via a dedicated settings tab with `+` / `-` controls |
| Sensitivity | Low / Medium / High — adjusts the p90 multiplier threshold |
| Launch at login | Registers/unregisters via `SMAppService` |
| Automatic updates | Enables background update checks via Sparkle; manual "Check for Updates" button always available |

---

## License

MIT — see `LICENSE` for details.
