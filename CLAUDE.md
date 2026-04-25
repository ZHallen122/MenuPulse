# CLAUDE.md — Bouncer

Quick-start reference for contributors and automated agents.

## Project overview

- Native macOS menu bar agent — **no main window**
- Monitors other menu bar apps for memory anomalies; sends actionable notifications
- macOS 13+ required, Xcode 15+ required
- Language: Swift / SwiftUI + AppKit (`NSStatusItem`, `NSPopover`)

## Build

Active developer directory must point to Xcode.app (not the CLI tools shim):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Bouncer.xcodeproj" \
           -scheme "Bouncer" \
           -configuration Debug build
```

## Run tests

The `"Bouncer"` scheme is **not** configured for testing. Use the dedicated test scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Bouncer.xcodeproj" \
           -scheme "BouncerTests" \
           -configuration Debug test
```

## Entry point

`App/BouncerApp.swift` — SwiftUI `@main` `App` struct.  
It wires `AppDelegate` (`App/AppDelegate.swift`) via `@NSApplicationDelegateAdaptor`; `AppDelegate` owns the `NSStatusItem` and `NSPopover`.

## Key layers

| Layer | Files |
|---|---|
| Entry / lifecycle | `App/BouncerApp.swift`, `App/AppDelegate.swift` |
| Sampling | `Sampling/ProcessMonitor.swift`, `Sampling/ProcessMonitor+Enumeration.swift`, `Sampling/ProcessMonitor+HelperFolding.swift`, `Sampling/ProcessMonitor+XPCCache.swift`, `Sampling/MemoryPressure.swift`, `Sampling/SwapMonitor.swift`, `Sampling/MenuBarProcess.swift`, `Sampling/ProcessSyscall.swift` |
| Detection | `Detection/AnomalyDetector.swift` |
| Icon coloring | `App/IconColorLogic.swift` |
| Storage | `Storage/DataStore.swift`, `Storage/DataStore+Schema.swift`, `Storage/DataStore+Samples.swift`, `Storage/DataStore+Baseline.swift`, `Storage/DataStore+AlertEvents.swift` (SQLite) |
| Popover root | `UI/Popover/StatusMenuView.swift` (SwiftUI popover root; shows process list with sparklines and anomaly highlights) |
| HUD UI | `UI/HUD/HUDView.swift`, `UI/HUD/HUDWindow.swift`, `UI/HUD/HUDProcessRow.swift`, `UI/HUD/ThermalHeaderView.swift`, `UI/HUD/RAMBarView.swift`, `UI/HUD/ProcessDetailSheet.swift`, `UI/HUD/ThermalState+Display.swift` |
| History UI | `UI/History/HistoryView.swift`, `UI/History/HistoryWindow.swift` (top-offenders leaderboard + per-app memory timeline) |
| Sparkline widget | `UI/Popover/SparklineView.swift` (`Canvas`-based rolling memory sparkline) |
| Settings | `UI/Settings/PreferencesManager.swift`, `UI/Settings/SettingsView.swift` |
| Onboarding | `UI/Onboarding/OnboardingView.swift` |
| Auto-update | `Updates/SparkleUpdater.swift` |
