# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.1] - 2026-04-25

### Added

- Added a security policy for responsible vulnerability reporting.

### Changed

- Refreshed the app icon assets for a clearer Bouncer identity.
- Updated README wording to better match the shipped behavior and open-source release expectations.

### Fixed

- Fixed the popover so the process list is populated on first open.
- Forced dark appearance for popover/HUD host windows so tinted controls render consistently.

## [1.0] - 2026-04-25 — Bouncer launch

### Changed

- **Renamed to Bouncer** — the project, build product, Xcode targets, schemes, source folders, `@main` struct, and bundle identifiers were renamed from "Menu Bar Diagnostic" / `com.allenz.MenuBarDiagnostic` to "Bouncer" / `com.allenz.Bouncer`. **Existing installs will not auto-update via Sparkle because the bundle ID changed — please reinstall from the v1.0 release.**
- **Block List settings tab** — dedicated UI in Settings for managing ignored bundle IDs; replaces the old comma-separated text field with a proper list view with `+` / `-` controls
- **App count in status menu** — the "N apps running" summary now reflects the filtered list (block-listed apps excluded from count)
- **Process list display** — anomalous and normal processes render in a single unified list, with anomalous entries always sorted to the top followed by remaining processes ordered by memory usage

## [Pre-rebrand history] — Menu Bar Diagnostic 1.0–1.0.2 (2026-04-10 to 2026-04-12)

### Added

- **Menu bar agent** — native macOS menu bar app with no main window, showing a live status icon and popover HUD
- **Memory anomaly detection** — 3-day adaptive learning period establishes per-process baselines; alerts fire when usage deviates significantly from learned norms
- **Swap detection** — monitors swap file activity and reflects severity in icon color (orange = elevated, red = critical) with actionable user notifications
- **Thermal state display** — header in the HUD shows current system thermal pressure level
- **RAM bar** — visual overview of system RAM pressure in the popover
- **Sparklines** — per-process memory trend sparklines in the process list
- **Process detail sheet** — tap any row to view a full history chart and metadata for that process
- **SQLite-backed data store** — all samples and baselines persisted locally via `DataStore.swift` for continuity across launches
- **Settings window** — standalone `NSWindow` with a tab layout for configuring thresholds, notification preferences, and update intervals (`PreferencesManager`, `SettingsView`)
- **Notification hardening** — robust error handling on `UNUserNotificationCenter` requests; duplicate suppression to avoid alert fatigue
- **Test coverage** — 18+ unit tests covering anomaly detection logic, data store operations, and edge cases

### Architecture

- Entry point: `BouncerApp.swift` (SwiftUI `@main` App) wiring `AppDelegate`
- `AppDelegate` owns `NSStatusItem` and `NSPopover`
- Sampling layer: `ProcessMonitor.swift`, `MemoryPressure.swift`
- Detection layer: `AnomalyDetector.swift`
- Storage layer: `DataStore.swift` (SQLite)
- HUD UI: `HUDView`, `HUDWindow`, `HUDProcessRow`, `ThermalHeaderView`, `RAMBarView`, `ProcessDetailSheet`

### Requirements

- macOS 13+
- Xcode 15+
