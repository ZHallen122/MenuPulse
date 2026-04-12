# CLAUDE.md — Menu Bar Diagnostic (Bouncer)

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
xcodebuild -project "Menu Bar Diagnostic.xcodeproj" \
           -scheme "Menu Bar Diagnostic" \
           -configuration Debug build
```

## Run tests

The `"Menu Bar Diagnostic"` scheme is **not** configured for testing. Use the dedicated test scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Menu Bar Diagnostic.xcodeproj" \
           -scheme "MenuBarDiagnosticTests" \
           -configuration Debug test
```

## Entry point

`MenuBarDiagnosticApp.swift` — SwiftUI `@main` `App` struct.  
It wires `AppDelegate` via `@NSApplicationDelegateAdaptor`; `AppDelegate` owns the `NSStatusItem` and `NSPopover`.

## Key layers

| Layer | Files |
|---|---|
| Entry / lifecycle | `MenuBarDiagnosticApp.swift`, `AppDelegate.swift` |
| Sampling | `ProcessMonitor.swift`, `MemoryPressure.swift`, `SwapMonitor.swift` |
| Detection | `AnomalyDetector.swift` |
| Icon coloring | `IconColorLogic.swift` |
| Storage | `DataStore.swift` (SQLite) |
| Popover root | `StatusMenuView.swift` (SwiftUI popover root; shows process list with sparklines and anomaly highlights) |
| HUD UI | `HUDView.swift`, `HUDWindow.swift`, `HUDProcessRow.swift`, `ThermalHeaderView.swift`, `RAMBarView.swift`, `ProcessDetailSheet.swift` |
| History UI | `HistoryView.swift`, `HistoryWindow.swift` (top-offenders leaderboard + per-app memory timeline) |
| Sparkline widget | `SparklineView.swift` (`Canvas`-based rolling memory sparkline) |
| Settings | `PreferencesManager.swift`, `SettingsView.swift` |
| Onboarding | `OnboardingView.swift` |
| Auto-update | `SparkleUpdater.swift` |
