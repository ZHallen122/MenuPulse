# Bouncer

A native macOS menu bar app that watches user-visible apps for memory anomalies and swap pressure, then surfaces actionable alerts before they slow your system down.

<img width="328" height="452" alt="image" src="https://github.com/user-attachments/assets/68212162-10c2-4301-a77a-25af2b9bdc08" />





---

## What it does

Bouncer sits in your menu bar as a stethoscope-themed status item. It samples user-visible running apps, folds common helper processes into their parent app, and stores local memory baselines in SQLite. When an app shows a sustained upward memory trend while system memory pressure is elevated, Bouncer notifies you with **Restart Now** or **Ignore** actions so you can act before the app causes a slowdown.

The icon color reflects current system state at a glance:

| Color | Meaning |
|---|---|
| Green | All clear |
| Yellow | Memory anomaly, compressed-memory growth, or minor swap growth |
| Orange | Significant swap growth |
| Red | Critical swap growth |

---

## Features

- **Three-condition anomaly detection** — An app is flagged only when all three are true simultaneously:
  1. Current memory > p90 baseline × sensitivity multiplier
  2. 30-minute upward trend (linear regression slope > 0)
  3. System memory pressure is Warning or Critical
- **Phased learning period** — Newly seen apps move through `learning_phase_1`, `learning_phase_2`, `learning_phase_3`, and `active` over roughly 3 days. Early phases use looser thresholds while the baseline is still forming.
- **Actionable notifications** — Each alert offers **Restart Now** (relaunches the offending app) or **Ignore**. Ignored apps are added to the ignored-app list, and a 24-hour per-app cooldown prevents repeat notifications.
- **10-minute persistence gate** — An app must remain anomalous for 10 continuous minutes before a notification fires.
- **Memory sparklines** — Click the status icon to open the popover and see rolling memory sparklines for the top monitored apps. Anomalous apps are highlighted in amber.
- **Swap and compressed-memory detection** — `SwapMonitor` polls `vm.swapusage` and compressed memory every 30 seconds, using a 5-minute rolling delta. Significant swap growth triggers a notification with **Quit Top App** / **View All** / **Dismiss** actions (1-hour cooldown).
- **Settings** — Configure sensitivity (Conservative / Default / Aggressive), launch at login, menu bar RAM percentage, automatic update preference, and ignored bundle IDs via a list UI with `+` / `-` controls.
- **First-launch onboarding** — On first run a welcome sheet explains what Bouncer does and requests notification permission. Shown once, gated by `hasShownOnboarding`.
- **History window** — A "History" button in the popover opens a standalone window with a top-offenders leaderboard (ranked by alert count) and a per-app alert-event timeline. Results can be filtered to the last 7 or 30 days; tapping any leaderboard row drills into that app's timeline.
- **Automatic updates** — Sparkle 2.9.1 is integrated for background and manual update checks. Release builds must provide a real Sparkle appcast URL and signing key before distribution.

---

## Architecture

```
BouncerApp (@main, SwiftUI App)
└── AppDelegate (via @NSApplicationDelegateAdaptor)
    ├── NSStatusItem (stethoscope icon, green/orange/red tint)
    └── NSPopover → StatusMenuView (SwiftUI)

ProcessMonitor  ──samples every 2s──►  AnomalyDetector
     │                                       │
     │  (regular/accessory apps)             │  evaluates 3 conditions
     ▼                                       ▼
 DataStore (SQLite)              UNUserNotificationCenter
   per-app memory samples          "Restart Now" / "Ignore"
   p90 baseline computation
```

### Data flow

1. `ProcessMonitor` samples user-visible regular and accessory-policy apps every 2 seconds via `proc_pidinfo` / `proc_pid_rusage`, collecting CPU and physical memory footprint for each.
2. Every 30 seconds, samples are stored in `DataStore` (SQLite). The store computes median and p90 baselines per bundle ID and prunes old samples.
3. `AnomalyDetector` evaluates the three conditions on every sample tick and publishes `anomalousBundleIDs`.
4. After 10 continuous minutes of anomaly, `AnomalyDetector` posts a `UNUserNotification` for that app (subject to the 24-hour cooldown).
5. `AnomalyDetector` handles the notification response: **Restart Now** terminates and relaunches the app; **Ignore** adds the bundle ID to the ignored-app list.
6. `StatusMenuView` (in the popover) observes `ProcessMonitor` and `AnomalyDetector` and renders the process list with amber highlights for anomalous apps.

### Key files

| File | Role |
|---|---|
| `App/BouncerApp.swift` | SwiftUI `@main` entry point; wires `AppDelegate` via `@NSApplicationDelegateAdaptor` |
| `App/AppDelegate.swift` | Owns `NSStatusItem`, `NSPopover`, notification handling |
| `App/IconColorLogic.swift` | Pure `iconColor()` function; maps `SwapState` + `pendingAnomalyAlert` → `NSColor` for the status bar icon |
| `Sampling/ProcessMonitor.swift` | Sampling engine; publishes `[MenuBarProcess]` and system memory pressure |
| `Sampling/ProcessMonitor+Enumeration.swift` | Process enumeration helpers for user-visible regular and accessory-policy apps |
| `Sampling/ProcessMonitor+HelperFolding.swift` | Folds child/helper processes into their parent menu-bar app for aggregate memory accounting |
| `Sampling/ProcessMonitor+XPCCache.swift` | Caches XPC service bundle lookups so repeated sampling doesn't hit the filesystem |
| `Sampling/MemoryPressure.swift` | System memory pressure reading utilities |
| `Sampling/SwapMonitor.swift` | `ObservableObject` that polls `vm.swapusage` and compressed memory every 30 s; publishes swap stats and `SwapState`; posts swap-growth notifications |
| `Sampling/MenuBarProcess.swift` | Immutable value-type snapshot of a single process |
| `Sampling/ProcessSyscall.swift` | Thin wrapper around `proc_pidinfo` and related syscalls used by the sampler |
| `Detection/AnomalyDetector.swift` | Three-condition evaluator; posts notifications; owns anomaly timers and cooldowns |
| `Storage/DataStore.swift` | SQLite wrapper; stores per-app samples, computes p90 baseline |
| `Storage/DataStore+Schema.swift` | Schema creation and migration for memory samples, baselines, lifecycle state, and alert events |
| `Storage/DataStore+Samples.swift` | Insert, query, and pruning of per-app memory samples |
| `Storage/DataStore+Baseline.swift` | p90 baseline computation per bundle ID over the rolling sample window |
| `Storage/DataStore+AlertEvents.swift` | Recording and retrieval of alert events for the History window |
| `UI/Popover/StatusMenuView.swift` | SwiftUI popover root; shows process list with sparklines and anomaly highlights |
| `UI/Popover/SparklineView.swift` | `Canvas`-based rolling memory sparkline |
| `UI/HUD/HUDView.swift` | Main popover HUD listing all monitored processes |
| `UI/HUD/HUDWindow.swift` | `NSWindow` subclass that hosts the HUD |
| `UI/HUD/HUDProcessRow.swift` | Single process row with alert-threshold highlighting |
| `UI/HUD/ThermalHeaderView.swift` | Header showing system thermal/memory pressure state |
| `UI/HUD/RAMBarView.swift` | Visual RAM usage bar component |
| `UI/HUD/ProcessDetailSheet.swift` | Expanded detail sheet for a single process |
| `UI/HUD/ThermalState+Display.swift` | Extension adding display strings to `ProcessInfo.ThermalState` |
| `UI/History/HistoryView.swift` | History window SwiftUI view; top-offenders leaderboard and per-app alert-event timeline |
| `UI/History/HistoryWindow.swift` | `NSWindow` subclass that hosts the history view |
| `UI/Settings/PreferencesManager.swift` | `ObservableObject` wrapping `@AppStorage` user preferences |
| `UI/Settings/SettingsView.swift` | SwiftUI settings UI (sensitivity, launch at login, menu bar RAM percentage, update checks, ignored bundle IDs; DEBUG builds also show developer testing controls) |
| `UI/Onboarding/OnboardingView.swift` | First-launch onboarding sheet; requests notification permission; gated by `hasShownOnboarding` UserDefaults key |
| `Updates/SparkleUpdater.swift` | Sparkle 2.9.1 wrapper for update checks |

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
   open "Bouncer.xcodeproj"
   ```

2. Select the **Bouncer** scheme and your Mac as the run destination.

3. Press **⌘R** to build and run.

> The app has no main window. After launch it appears only as a stethoscope icon in the menu bar.

### Command-line build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Bouncer.xcodeproj" \
           -scheme "Bouncer" \
           -configuration Debug build
```

### Running tests

The main scheme is not configured for testing. Use the dedicated test scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Bouncer.xcodeproj" \
           -scheme "BouncerTests" \
           -configuration Debug \
           -derivedDataPath build \
           -destination "platform=macOS,arch=$(uname -m)" test
```

---

## Settings

| Setting | Description |
|---|---|
| Ignored Apps | Apps in this list are never monitored or alerted on; managed via a dedicated settings tab with `+` / `-` controls |
| Sensitivity | Conservative / Default / Aggressive — adjusts the p90 multiplier threshold |
| Launch at login | Registers/unregisters via `SMAppService` |
| Show RAM Usage in Menu Bar | Shows current RAM usage percentage next to the menu bar icon |
| Automatic updates | Preference shown in Settings; Sparkle uses the published appcast when release builds are distributed |

## Privacy

Bouncer runs locally. It samples process names, bundle identifiers, CPU, memory footprint, memory pressure, swap usage, and compressed-memory usage, then stores local SQLite history for baselines and alert history. It does not upload telemetry. The only intended network access is Sparkle update checking when configured for a release build.

## Release notes for maintainers

- `Bouncer/Info.plist` contains the Sparkle `SUFeedURL` and public EdDSA key used by release builds.
- The GitHub release workflow expects Apple Developer ID secrets and `SPARKLE_EDDSA_KEY`, then generates `appcast.xml` from the release archive.
- Enable GitHub Pages for the `main` branch root so `https://zhallen122.github.io/Bouncer/appcast.xml` is publicly reachable.
- Commit `Bouncer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` so Sparkle remains pinned for contributors and CI.

---

## License

MIT — see `LICENSE` for details.
