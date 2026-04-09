# Menu Bar Diagnostic

A native macOS menu bar app that monitors all other menu bar processes in real time — showing per-process CPU, RAM, sparkline history, and a live thermal heatmap header.

<!-- screenshot: menu-bar-icon -->

---

## Features

- **Live process list** — Shows every running accessory-policy app (i.e. menu bar apps) with CPU%, RAM, and app icon.
- **Sparkline CPU history** — Rolling 20-sample sparkline chart per process showing CPU trend over time.
- **RAM bar views** — Visual proportional RAM bars for quick at-a-glance comparison.
- **Thermal state heatmap header** — Color-coded header that reflects the system's current thermal pressure (nominal → fair → serious → critical).
- **System-wide CPU & RAM** — Aggregate CPU fraction via `host_statistics` tick deltas; RAM via `vm_statistics64` (active + wired + compressor pages).
- **Alert glow on CPU hogs** — Rows with sustained high CPU pulse with a red glow animation.
- **Animated gradient border** — HUD overlay uses an animated gradient border for a glass-morphism aesthetic.
- **HUD overlay** — Floating always-on-top window (Option+click the status icon to toggle).
- **Process detail sheet** — Tap any row to open a detail sheet showing open file descriptor count and a SIGTERM kill button.
- **Badge count** — Status bar icon shows the number of currently running menu bar processes.
- **Settings sheet** — Configure refresh interval, CPU alert threshold, and RAM alert threshold via `@AppStorage`-backed preferences.

<!-- screenshot: status-menu-popover -->
<!-- screenshot: hud-overlay -->
<!-- screenshot: process-detail-sheet -->
<!-- screenshot: settings-sheet -->

---

## Architecture Overview

```
AppDelegate
├── NSStatusItem (stethoscope icon + badge count)
├── NSPopover → StatusMenuView (SwiftUI)
│   └── ProcessMonitor (ObservableObject)
│       ├── [MenuBarProcess] — value types published each sample tick
│       ├── systemCPUFraction — host_statistics tick delta
│       └── systemRAMUsedBytes / systemRAMTotalBytes — vm_statistics64
└── HUDWindow (NSWindow, borderless, always-on-top)
    └── HUDView (SwiftUI root)
        ├── ThermalHeaderView
        ├── HUDProcessRow (per process)
        │   ├── SparklineView
        │   └── RAMBarView
        └── ProcessDetailSheet (sheet overlay)
```

### Data Flow

1. **Sampling** — `ProcessMonitor.sample()` fires on a `Timer` at the configured refresh interval (default 2 s).
2. **Per-process CPU** — `proc_pidinfo(PROC_PIDTASKINFO)` fetches accumulated CPU nanoseconds. Delta over wall-clock nanoseconds gives a 0–1 CPU fraction, capped at 1.0.
3. **CPU history** — Each PID's fraction is appended to a rolling `[Double]` buffer (max 20 entries) stored in `cpuHistories`. Stale PIDs are pruned after each sample.
4. **System CPU** — `host_statistics(HOST_CPU_LOAD_INFO)` returns tick counters. Wrapping-safe subtraction from the previous sample gives a per-interval fraction across user + sys + nice ticks.
5. **System RAM** — `host_statistics64(HOST_VM_INFO64)` returns page counts. Active + wired + compressor pages × page size = used bytes. Total physical RAM is read once via `sysctlbyname("hw.memsize")` and cached.
6. **Publishing** — Results are dispatched to the main queue and published as `@Published` properties, driving SwiftUI view updates.
7. **User interaction** — Left-click toggles the `NSPopover`; Option+left-click toggles the `HUDWindow`.

### Key Components

| File | Role |
|---|---|
| `ProcessMonitor.swift` | Sampling engine; owns the timer, previous-sample dictionaries, and publishes results |
| `MenuBarProcess.swift` | Immutable value type snapshot of a single process; computed display properties |
| `AppDelegate.swift` | App entry point; owns `NSStatusItem`, `NSPopover`, and `HUDWindow` |
| `HUDView.swift` | Root SwiftUI view for the floating HUD overlay |
| `HUDWindow.swift` | Custom `NSWindow` subclass — borderless, always-on-top, translucent |
| `HUDProcessRow.swift` | Per-process row with sparkline and RAM bar |
| `SparklineView.swift` | `Canvas`-based sparkline for CPU history |
| `RAMBarView.swift` | Proportional horizontal RAM bar |
| `ThermalHeaderView.swift` | Heatmap header row driven by `ProcessInfo.thermalState` |
| `ThermalState+Display.swift` | Extension mapping `ThermalState` → label + color |
| `StatusMenuView.swift` | SwiftUI root for the `NSPopover` content |
| `PreferencesManager.swift` | `ObservableObject` wrapping `@AppStorage` user preferences |
| `ProcessDetailSheet.swift` | Sheet showing open FD count + SIGTERM kill button |
| `SettingsView.swift` | SwiftUI preferences UI |

---

## Building and Running

### Requirements

- macOS 13 Ventura or later
- Xcode 15+

### Steps

1. Clone the repository:
   ```bash
   git clone <repo-url>
   cd Menu-Bar-Diagnostic
   ```

2. Open the Xcode project:
   ```bash
   open "Menu Bar Diagnostic.xcodeproj"
   ```

3. Select the **Menu Bar Diagnostic** scheme and your Mac as the run destination.

4. Press **⌘R** to build and run.

> **Note:** The app has no main window. After launch it appears only as a stethoscope icon in the menu bar.

### Usage

| Action | Result |
|---|---|
| Click status icon | Opens the process list popover |
| Option+click status icon | Toggles the floating HUD overlay |
| Click a process row | Opens the process detail sheet |
| Kill button in detail sheet | Sends SIGTERM to the selected process |

---

## Code Signing & Entitlements

`proc_pidinfo` requires that the calling process has sufficient privileges to inspect other processes. In practice:

- **Development (local):** A standard developer-signed build (automatic signing in Xcode) works without any special entitlements on your own machine.
- **Distribution outside the App Store:** The app needs the `com.apple.security.temporary-exception.mach-lookup` entitlement (or equivalent) to query arbitrary process task info. Add this to `MenuBarDiagnostic.entitlements` and request a Provisioning Profile that includes the exception.
- **Mac App Store:** MAS sandboxing prevents `proc_pidinfo` on other processes entirely. Distribution via MAS would require a fundamentally different approach (e.g., an XPC helper with a privileged helper tool).

For local development the default Xcode automatic signing team is sufficient — no manual entitlement changes are needed.

---

## License

MIT — see `LICENSE` for details.
