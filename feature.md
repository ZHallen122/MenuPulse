# Bouncer — Feature Reference

Complete description of every feature in the app. Intended as a living document; update when features are added, changed, or removed.

---

## 1. Menu Bar Agent

Bouncer runs as a native macOS menu bar agent — no Dock icon, no main window. It appears only as a stethoscope-themed icon in the system menu bar. The icon is always visible while the app is running and serves as the primary status indicator and entry point for all UI.

**Files:** `BouncerApp.swift`, `AppDelegate.swift`

---

## 2. Status Icon Color Coding

The icon tint changes every sample tick to reflect the most severe system condition:

| Color | Condition |
|---|---|
| Green | All clear — no swap, no anomalies detected |
| Yellow | At least one app has an active memory anomaly |
| Orange | Swap memory is in use |
| Red | Swap memory is actively growing (> ~10 MB/min) |

Color is computed by a pure function `iconColor(swapState:pendingAnomalyAlert:)` so it is fully unit-testable without any UI.

**Files:** `IconColorLogic.swift`, `AppDelegate.swift`

---

## 3. Popover HUD

Clicking the menu bar icon opens a `NSPopover` anchored to the status item. The popover hosts a SwiftUI view tree (`StatusMenuView` → `HUDView`) that shows:

- **Thermal / RAM header** — current system thermal state and a visual RAM pressure bar.
- **Process list** — all monitored apps sorted by memory usage, with anomalous apps pinned to the top and highlighted in amber.
- **Per-row sparklines** — rolling 20-sample memory trend chart for each process.
- **History button** — opens the standalone History window.
- **Settings button** — opens the Settings window.

The popover closes automatically when the user clicks outside it. SwiftUI `@Published` state mutations are suppressed while the popover is hidden to avoid unnecessary CPU work.

**Files:** `StatusMenuView.swift`, `HUDView.swift`, `HUDWindow.swift`, `HUDProcessRow.swift`, `ThermalHeaderView.swift`, `RAMBarView.swift`

---

## 4. Memory Sparklines

Every process row in the HUD renders a `Canvas`-based rolling sparkline of the last 20 memory-footprint samples (in MB), updated each tick. The chart gives an instant visual read on whether an app's memory is stable, growing, or declining — without requiring the user to open a detail sheet.

**Files:** `SparklineView.swift`

---

## 5. Process Detail Sheet

Tapping any row in the process list expands a full-screen detail sheet for that app showing:

- App icon, name, bundle ID, and launch date.
- Full memory history chart with a longer time axis.
- Current memory footprint, CPU fraction, and lifecycle phase.

**Files:** `ProcessDetailSheet.swift`

---

## 6. Process Sampling Engine

`ProcessMonitor` drives a repeating timer (default 2-second interval) that:

1. Queries all running PIDs via `proc_listpids`.
2. Resolves each PID to its `NSRunningApplication` metadata on first encounter only (strict IPC guard — cached for all subsequent ticks via `appStaticCache`).
3. Reads CPU time via `proc_pidinfo` / `PROC_PIDTASKINFO` and computes a per-interval CPU fraction.
4. Reads physical memory footprint via `proc_pid_rusage` / `rusage_info_v4.ri_phys_footprint` (matches Activity Monitor's "Memory" column).
5. Maintains 20-sample rolling histories for CPU and memory per PID.
6. Publishes results back on the main queue; suppresses redundant SwiftUI fires when the UI is hidden.

All syscalls run on a dedicated `.utility` serial queue (`sampleQueue`) to keep the main thread free.

**Files:** `ProcessMonitor.swift`, `MenuBarProcess.swift`

---

## 7. Helper Process Folding (PPID Grouping)

Child helper processes (Chrome Helper, Electron renderers, Safari WebContent, etc.) are folded into their parent app's memory total so each app appears as a single row rather than scattered helpers. The fold is implemented as a two-pass algorithm:

- **Pass 1** — helpers that cleared the `NSRunningApplication` filter and landed in the process dict are identified by PPID and folded in.
- **Pass 2** — helpers that were filtered out (`.prohibited` activation policy or no `NSRunningApplication` entry) are caught by iterating raw PID list and calling `proc_pid_rusage` directly for any PID whose PPID maps to a tracked app.

PPID resolution uses `ProcessSyscall.getParentPID(of:)` — a zero-heap-allocation wrapper around `proc_pidinfo` / `PROC_PIDTBSDINFO`.

**Files:** `ProcessSyscall.swift`, `ProcessMonitor.swift`

---

## 8. Memory Anomaly Detection

`AnomalyDetector` evaluates three conditions on every sample tick. All three must hold simultaneously to flag an app:

1. **Threshold breach** — current memory > p90 baseline × sensitivity multiplier.
2. **Sustained upward trend** — linear regression slope over the last 30 minutes is positive.
3. **System pressure** — system memory pressure is `.warning` or `.critical`.

Additional safeguards:

- **10-minute persistence gate** — an app must remain anomalous for 10 consecutive minutes before a notification fires.
- **24-hour per-app cooldown** — suppresses repeat notifications for the same app.
- **4-phase lifecycle gate** — newly seen apps go through `learning_phase_1 → 2 → 3 → active` (4 h / 24 h / 3 days thresholds). Earlier phases use looser, median-based thresholds to avoid false positives while the baseline is still being established. Only `active` apps are evaluated against the full p90 baseline.

**Files:** `AnomalyDetector.swift`, `DataStore.swift`

---

## 9. Actionable Notifications

When an anomaly is confirmed, Bouncer posts a `UNUserNotification` with two action buttons:

- **Restart Now** — terminates and relaunches the offending app via `NSWorkspace`.
- **Ignore** — dismisses the alert; the app remains monitored but won't fire again for 24 hours.

Notifications are deduplicated to avoid alert fatigue. On first launch, an onboarding sheet requests `UNUserNotificationCenter` permission.

**Files:** `AnomalyDetector.swift`, `AppDelegate.swift`

---

## 10. Swap Memory Monitoring

`SwapMonitor` polls `vm.swapusage` via `sysctl` every 30 seconds and publishes:

- Current swap bytes used and total swap capacity.
- A `SwapState` enum: `.normal`, `.compressedGrowing`, `.swapMinor`, `.swapSignificant`, `.swapCritical`.

When swap transitions from inactive to active, Bouncer posts a notification with three actions: **Quit Top App**, **View All**, and **Dismiss**. A 1-hour cooldown prevents repeat swap alerts.

**Files:** `SwapMonitor.swift`, `AppDelegate.swift`

---

## 11. SQLite Data Store

All memory samples and per-app baselines are persisted locally in a SQLite database via `DataStore`:

- **`memory_samples` table** — raw per-app footprint samples with timestamps.
- **`app_baselines` table** — computed p90 baseline per bundle ID.
- **`app_lifecycle` table** — per-app lifecycle state, version, and `last_seen_at`.
- **`alert_events` table** — historical record of every fired anomaly alert with peak memory, start/end timestamps, and alert count.

SQLite is configured in WAL mode for reduced write latency. Samples older than 3 days are purged each persist tick. Baselines are recomputed on a 30-second throttled interval (5-second interval in testing mode).

**Files:** `DataStore.swift`

---

## 12. History Window

A standalone `NSWindow` (opened via the "History" button in the popover) showing:

- **Top Offenders leaderboard** — apps ranked by total alert count, with peak memory and last-seen date. Filterable to the last 7 or 30 days.
- **Per-app timeline** — selecting any leaderboard row drills into a chart of that app's alert events over time.

**Files:** `HistoryView.swift`, `HistoryWindow.swift`

---

## 13. Settings

A standalone `NSWindow` with two tabs:

### General tab
| Setting | Description |
|---|---|
| Sensitivity | Low / Medium / High — adjusts the p90 multiplier threshold used in anomaly detection |
| Launch at login | Registers / unregisters the app via `SMAppService` |
| Automatic updates | Enables background update checks via Sparkle; a manual "Check for Updates" button is always available |
| Testing mode | Accelerates sampling intervals for development / QA |

### Block List tab
A managed list of ignored bundle IDs. Apps on the block list are never monitored, never alerted on, and excluded from the process count shown in the popover. Entries are added via a sheet that browses running apps and removed with a `-` button.

**Files:** `PreferencesManager.swift`, `SettingsView.swift`

---

## 14. First-Launch Onboarding

On first run a welcome sheet (`OnboardingView`) explains what Bouncer does, shows a brief feature summary, and requests `UNUserNotificationCenter` authorization. The sheet is shown exactly once, gated by the `hasShownOnboarding` key in `UserDefaults`.

**Files:** `OnboardingView.swift`

---

## 15. Automatic Updates

Sparkle 2.9.1 is embedded to provide silent background update checks and a manual "Check for Updates" flow from Settings. Update checks respect the "Automatic updates" preference toggle.

**Files:** `SparkleUpdater.swift`

---

## 16. Performance Optimizations

Several optimizations keep Bouncer's own resource footprint minimal:

- **Strict IPC guard** — `NSRunningApplication(processIdentifier:)` is called at most once per PID (on first encounter); all subsequent ticks read from `appStaticCache`.
- **`reserveCapacity()`** — the intermediate process dict and final result array are pre-sized to the current PID count each tick.
- **Per-iteration autorelease pools** — each iteration of the main sampling loop and the helper-fold pass is wrapped in `autoreleasepool {}` so ObjC temporaries (icon images, localized names, bundle URLs) are released immediately rather than accumulating until the loop exits.
- **Off-main sampling** — all syscalls run on a dedicated `.utility` serial queue; the main thread is never blocked.
- **UI-gated publishes** — `@Published` state mutations for the process list are skipped entirely when the popover and HUD are both hidden.
- **SQLite WAL mode** — reduces write contention and keeps disk I/O off the hot path.

**Files:** `ProcessMonitor.swift`, `ProcessSyscall.swift`, `DataStore.swift`
