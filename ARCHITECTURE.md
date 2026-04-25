# Architecture

Bouncer's source tree is organized into layered folders under `Bouncer/`. Each folder has a single responsibility; cross-layer wiring happens in `App/AppDelegate.swift`. When adding a new file, pick the folder whose description matches — if nothing fits, the layering is probably wrong, not the folder list.

## App/

Entry point and top-level lifecycle wiring. Contains `BouncerApp` (the SwiftUI `@main`), `AppDelegate` (owns `NSStatusItem`, `NSPopover`, and the notification handlers), and `IconColorLogic` (pure mapping from swap/anomaly state → status-bar tint). Does NOT contain sampling, detection, persistence, or reusable views.

## Sampling/

Polling and measurement producers. `ProcessMonitor` (plus its `+Enumeration`, `+HelperFolding`, `+XPCCache` extensions) samples accessory-policy processes every 2 s; `MemoryPressure` reads system pressure; `SwapMonitor` polls `vm.swapusage`; `ProcessSyscall` wraps `proc_pidinfo`; `MenuBarProcess` is the immutable snapshot value type. Does NOT evaluate anomalies, persist, or render.

## Detection/

Evaluators that turn samples into alerts. Currently just `AnomalyDetector` (three-condition evaluator, persistence gate, per-app cooldowns). Future evaluators (e.g. swap-growth, CPU) belong here. Does NOT sample, persist raw samples, or render.

## Storage/

SQLite persistence. `DataStore` plus the `+Schema`, `+Samples`, `+Baseline`, and `+AlertEvents` extensions — one file per concern, same `DataStore` class. Owns the DB file, schema migrations, sample insert/prune, p90 baseline computation, and alert-event history. Does NOT import SwiftUI and does NOT reach up into sampling or detection.

## UI/

SwiftUI + AppKit views, grouped by surface. Every file under `UI/` is a view or view-support type. Views observe published state from `Sampling/`, `Detection/`, and `Storage/` — they never perform syscalls or SQL themselves.

## UI/Popover/

The `NSPopover` opened from the status-bar icon. `StatusMenuView` is the root; `SparklineView` is the `Canvas`-based rolling memory widget embedded per row.

## UI/HUD/

The standalone HUD window. `HUDWindow` hosts `HUDView`, which composes `ThermalHeaderView`, `RAMBarView`, and a list of `HUDProcessRow`s, with `ProcessDetailSheet` as the drill-down. `ThermalState+Display` supplies display strings for `ProcessInfo.ThermalState`.

## UI/History/

The history window. `HistoryWindow` hosts `HistoryView`, which renders the top-offenders leaderboard and per-app alert timeline backed by `Storage/DataStore+AlertEvents`.

## UI/Settings/

Preferences UI. `PreferencesManager` is the `@AppStorage`-backed `ObservableObject`; `SettingsView` is the tabbed UI (sensitivity, launch-at-login, Block List).

## UI/Onboarding/

First-launch onboarding sheet. `OnboardingView` requests notification permission and is gated by the `hasShownOnboarding` `UserDefaults` key.

## Updates/

Sparkle auto-update wrapper. `SparkleUpdater` drives background and manual update checks. Nothing else lives here.

## Layer rules

- `Storage/` never imports SwiftUI — it is pure persistence. UI reads history by observing published state that `AppDelegate` hydrates from the store.
- `Sampling/` never touches `DataStore` directly. Sampling publishes snapshots; `AppDelegate` fans out each tick to `Storage/` (persist), `Detection/` (evaluate), and the UI (via `@Published` state).
- `UI/` never performs syscalls or SQL. Views observe `ProcessMonitor`, `AnomalyDetector`, `SwapMonitor`, and `DataStore` read APIs — they do not call `proc_pidinfo` or `sqlite3_*` themselves.
