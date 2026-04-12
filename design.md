



Bouncer
Product Development Document


"Activity Monitor, but it tells you what to do."



Version 1.0  |  April 2026
macOS  |  Apple Silicon  |  One-Time Purchase

1. Product Overview

1.1 One-Line Pitch

Core Value Proposition
"Activity Monitor, but it tells you what to do." — A lightweight macOS menu bar utility that proactively identifies which app is consuming your memory and recommends a one-click fix, before your Mac shows a low-memory alert.


1.2 Problem Statement
Mac users with limited RAM face a frustrating cycle: the Mac becomes sluggish, they open Activity Monitor, scan through hundreds of processes, guess which app is the culprit, manually kill it, and hope for the best. By the time they act, macOS has already shown a low-memory warning — the damage is done.

Existing tools address only parts of this problem:
iStat Menus shows system-wide memory totals, but not which specific app is causing pressure
Memory Clean 3 has a "Clean" button that purges cache, but doesn't identify the root cause
Activity Monitor shows every process, but is too broad and requires too much manual interpretation
macOS itself only alerts you after the system is already in crisis

1.3 Solution
Bouncer sits in your menu bar, silently watches memory pressure and per-process memory behavior, and speaks up only when it has something useful to say — specifically: which app is behaving abnormally, why it thinks so, and what to do about it.

1.4 Product Identity
Category
macOS Menu Bar Utility
Platform
macOS 13+ (Ventura and later), Apple Silicon optimized
Distribution
Direct sale (outside Mac App Store)
Pricing Model
One-time purchase, ~$19–22 USD
Target User
Mac power users with 8–16GB RAM (M1/M2/M3 MacBook users)
App Type
LSUIElement — no Dock icon, menu bar only



2. Target User

2.1 Primary Persona
Primary User: The Memory-Constrained Mac Developer / Creator
MacBook Pro or MacBook Air with 8–16GB unified memory. Runs 15–25 menu bar apps alongside Xcode, Figma, Chrome with many tabs, Slack, Notion, and Spotify simultaneously. Frequently hits the macOS low-memory alert and knows it's a real problem, but doesn't want to spend time debugging it.


2.2 Real Pain Scenario
The exact scenario that defines this product:

Trigger
Mac becomes sluggish or macOS shows low-memory alert
Current behavior
Open Activity Monitor → sort by memory → scan 300+ processes → guess the culprit → force quit → hope it helps
Frustration point
The entire process takes 2–5 minutes and requires manual judgment with no clear guidance
What they want
A single answer: "This app is the problem. Here's the button to fix it."
Willingness to pay
High — they hit this problem weekly or daily and know no good solution exists


2.3 Why Apple Silicon Makes This Worse
On M-series Macs, RAM is unified memory shared between CPU and GPU. A single app leaking 500MB directly degrades GPU performance, Metal rendering, and overall system responsiveness — more so than on traditional x86 architectures. Users on 8GB M1 MacBooks are particularly affected and represent a large segment of the Mac user base.


3. Competitive Landscape

3.1 Existing Tools
Tool
What It Does
Gap
Verdict
iStat Menus ($12)
Shows memory totals
No per-process blame
No recommendations
Memory Clean 3 (free)
Has "Clean" button
Shows memory hogs (info only)
No smart alerts
Activity Monitor (built-in)
Full process list
Manual interpretation required
No recommendations
macOS alert (built-in)
Forces action
Only fires at crisis point
No prevention
Bartender / Ice
Icon management only
Zero diagnostics
Completely different focus


3.2 The Gap
Market Gap Confirmed
No existing macOS app combines all three capabilities: (1) monitor Apple Memory Pressure, (2) identify the specific process causing it, and (3) proactively recommend action before the system alert fires. This three-column gap is the product opportunity.


3.3 Positioning
Bouncer does not compete with Bartender or Ice — those are icon organizers. Bouncer competes with the reflex of opening Activity Monitor. The positioning is not "better menu bar manager" but "smarter memory first responder."


4. Core Features (MVP)

4.1 Feature Hierarchy
Features are organized into three tiers based on their role in user adoption:

Tier 1 — Hook (Gets People to Install)

Agent Inventory
On first open, Bouncer shows a list of every running app with its current memory usage, sorted by consumption. Most users have never seen this list. The act of seeing it — especially the total RAM footprint — is itself the hook.


One-Click Cleanup Report
A summary card: "You have 19 running apps consuming 11.4GB RAM. 2 apps are behaving abnormally. 1 app hasn't been used in 14 days." This is the screenshot that earns organic Reddit shares.


Tier 2 — Value (Gets People to Pay)

Per-Process Memory Profiling
Live and historical memory usage for each individual process, using ri_phys_footprint (the same metric Apple's Activity Monitor uses). Not system totals — per app. Inline sparkline graphs show 30-minute trends at a glance.


Anomaly Detection with Smart Alerts
Bouncer learns each app's normal memory baseline over 3 days, then alerts you when an app significantly deviates — but only when Apple's Memory Pressure is also elevated. The combination of individual anomaly + system pressure minimizes false positives while ensuring timely alerts.


Pre-Crisis Notification with Action Button
Notification fires before macOS sends its low-memory alert. Shows the specific culprit and offers "Restart Now" directly in the notification — no need to open the app. This is the feature that replaces the Activity Monitor workflow.


Tier 2b — Swap Detection (Unique Differentiator)

Why Swap Detection Matters for Apple Silicon Users
On M-series Macs, when RAM is exhausted, macOS writes memory pages to the internal SSD (swap). This has two consequences: (1) performance degrades as SSD access is 10–100x slower than RAM, and (2) SSD write cycles are consumed, reducing hardware lifespan. Users with 8–16GB MacBooks are especially affected and rarely have visibility into when this is actively happening.


The key insight: macOS proactively moves inactive memory to swap even when overall pressure is green, meaning a large absolute swap value is normal and harmless. What matters is whether swap is actively growing. Bouncer monitors the rate of change (delta) of swap — not its absolute size — and only alerts when the system is actively writing to SSD at a meaningful rate. This distinction prevents the false positives that a naive implementation would produce constantly.

Additionally, Bouncer monitors Compressed memory as an earlier warning signal. Since macOS compresses RAM before writing to disk, rising Compressed memory is a leading indicator of approaching swap pressure, giving users a chance to act before SSD writes begin.

Swap Notification Template
Title: "Your Mac is using disk as memory"Body: "Swap in use: 2.1GB. Performance is degrading and your SSD is absorbing write pressure. Biggest contributor: Slack (1.1GB)."Actions: [Restart Slack]  [Quit Slack]  [View All]


Tier 3 — Retention (Gets People to Recommend It)

Weekly digest: top memory consumer, average RAM usage, swap events this week, suggested optimizations
Ghost process detection: apps whose menu bar icons are hidden but processes still consume RAM
Dead agent detection: LaunchAgents still running for apps that were deleted months ago
One-click restart: graceful terminate + relaunch without losing app state where possible


5. UX & Interaction Design

5.1 Core Design Principle
Design Philosophy
"Invisible when everything is fine. Unmissable when something needs attention." Bouncer should behave like a smoke detector — users forget it's there until it matters. The worst outcome is alert fatigue causing users to ignore or disable notifications.


5.2 Menu Bar Icon States
Bouncer uses a four-level color system. The addition of an Orange state — triggered by Swap usage — is a key differentiator. No existing tool specifically alerts when macOS begins writing memory to disk.

State
Meaning & Behavior
🟢 Green (default)
Normal memory pressure. Icon is muted, easy to ignore. Users spend the majority of their time here.
🟡 Yellow (warning)
A specific app has deviated significantly from its memory baseline AND system pressure is elevated. Bouncer knows who is responsible.
🟠 Orange (swap growing)
Swap is actively increasing at 500MB+ per 5 minutes. The system is writing to SSD right now — not historical swap data sitting idle, but real-time I/O pressure. Performance is degrading and SSD write cycles are being consumed. Triggered by delta, never by absolute swap size. This state is unique to Bouncer — no other menu bar tool surfaces it.
🔴 Red (critical)
Swap usage is growing rapidly and system is approaching crisis. Immediate action required.


5.3 Popover Layout
Clicking the menu bar icon opens a native NSPopover (not a window). Fixed width: 300px. Dynamic height up to 400px with scrolling. Two views accessible via a segmented control:

"Now" View — Default
Shows the current top memory consumers. Each row: app icon, app name, current RAM, and a small inline sparkline. Anomalous apps are pinned to the top with a subtle amber background. Normal apps are shown in subdued secondary text color. Clicking any row expands an inline detail card with:
Current vs. baseline memory
30-minute trend description ("increasing" / "stable" / "decreasing")
[Restart] — quit and relaunch, memory cleared, app stays running
[Quit] — gracefully exit, app removed from memory until manually reopened
[Disable at Login] — quit and remove from login items permanently
[Add to Ignore List] — stop monitoring this app

The three action buttons follow a severity gradient: Restart is the lightest intervention, Quit is moderate, and Disable at Login is the most permanent. This progression gives users a clear mental model for how to respond to different situations.

"History" View — Secondary
A 7-day timeline of memory pressure events, showing which app triggered each alert and what action was taken. Useful for identifying chronic offenders. Simple list, no complex charts.

5.4 Notification Design
Bouncer sends at most 2–3 notifications per day. Each notification follows this structure:

Notification Template
Title: "[App Name] memory abnormal"Body: "Using [X]GB — [N]x its normal level. System memory pressure is elevated."Actions: [Restart]  [Quit]  [Ignore]


The notification exposes two immediate actions:
Restart — gracefully quits and relaunches the app. Use this when you still need the app running but want to clear its memory leak.
Quit — gracefully quits the app without relaunching. Use this when you don't need the app right now and want to reclaim the RAM immediately.

Both actions execute directly from the notification without opening Bouncer. "Disable at Login" is intentionally omitted from the notification — it is a heavier, less reversible decision that belongs in the popover, not in a transient alert.

5.5 Settings
Deliberately minimal. Only four user-configurable items in v1:
Menu Bar Display — None (default) / Memory Pressure % / RAM Used. Allows users who want at-a-glance stats to opt in without changing the default experience for everyone else.
Ignore list — apps Bouncer should never alert about (e.g., Xcode, Figma — expected heavy users)
Sensitivity — Conservative / Default / Aggressive (controls the anomaly detection threshold multiplier)
Launch at login — on/off

No dashboards. No export. No profiles in v1. These are v2 considerations.


6. Technical Architecture

6.1 Tech Stack
Language
Swift 5.9+
UI Framework
AppKit (not SwiftUI — required for precise NSStatusItem control)
Data Storage
SQLite via GRDB.swift
Distribution
Sparkle framework for auto-updates (not Mac App Store)
Min OS
macOS 13 Ventura
Target Arch
Apple Silicon (arm64) primary, Universal Binary for Intel compatibility


6.2 System Architecture
Four layers, each with a clear responsibility:

Layer
Responsibility
System Layer
macOS API calls — reads memory pressure, per-process stats, running app list. No business logic.
Data Layer
SQLite storage of samples and computed baselines. Handles retention and cleanup.
Logic Layer
Anomaly detection engine. Combines process data with system pressure. Generates recommendations.
UI Layer
NSStatusItem icon, NSPopover, UNUserNotificationCenter. Purely presentational.


6.3 Key APIs

Memory Pressure (System-Level)
Read Apple's native memory pressure state using host_statistics64 with HOST_VM_INFO64. This is the same signal macOS uses internally — green / warning / critical. Polled every 30 seconds.

Per-Process Memory (ri_phys_footprint)
Use proc_pid_rusage(pid, RUSAGE_INFO_V4) to read ri_phys_footprint for each process. This metric matches what Activity Monitor displays and correctly accounts for Apple Silicon's unified memory architecture. Critical: do not use resident_size — it overstates memory usage by including shared libraries.

Running App Discovery
NSWorkspace.shared.runningApplications returns all running apps. Filter for apps with a valid bundleURL to exclude system daemons. For menu bar agents (LSUIElement = true), additionally parse their Info.plist to confirm they are user-installed agents.

Swap Usage Detection — Delta-Based Logic
Read swap usage via sysctlbyname("vm.swapusage"). Returns total swap capacity, bytes currently used, and bytes free. This API is public and requires no special permissions.

Critical Design Note: Delta Only, Never Absolute Value
A common implementation mistake is triggering alerts based on the absolute swap value (e.g., "swap > 0 = alert"). This produces constant false positives. macOS proactively writes inactive memory pages to SSD before pressure becomes critical — meaning a user can have 4GB of swap while memory pressure is completely green. That swap represents historical activity, not a current problem. Bouncer must monitor the rate of change (delta) of swap over time, not its absolute size.


The correct mental model: Swap absolute value = how much was written in the past. Swap delta = what is happening right now. Only the delta reflects real-time I/O pressure and active SSD consumption.

Compressed Memory as Early Warning Signal
macOS processes memory pressure in a strict priority order: free RAM first, then compress inactive pages (Compressed), then write to SSD (Swap). This means Compressed memory growing rapidly is a leading indicator that Swap pressure is coming. Bouncer monitors both metrics and uses Compressed growth as an earlier, softer warning before Swap activity begins.

Read Compressed memory via host_statistics64 with HOST_VM_INFO64, specifically the compressor_page_count field multiplied by the system page size.

Complete Alert Trigger Conditions
Condition
Icon State
Notification
Trigger
Compressed growing
🟡 Yellow
No notification
Compressed memory increases 300MB+ in 5 minutes. System is under pressure but managing without SSD writes yet. Early warning only.
Swap delta minor
🟡 Yellow
No notification
Swap increases 100–200MB in 5 minutes. System is beginning to write to SSD but at low intensity.
Swap delta significant
🟠 Orange
Yes — names top culprit
Swap increases 500MB+ in 5 minutes. Active I/O pressure. SSD write cycles being consumed at meaningful rate.
Swap delta critical
🔴 Red
Yes — urgent tone
Swap increases 1GB+ in 5 minutes. Severe active pressure. Performance degrading rapidly.
Swap static (any size)
No change
No notification
Swap absolute value is large but delta ≈ 0. This is historical data, not a current problem. Never alert on this.


At the moment a Swap delta threshold is crossed, Bouncer captures a snapshot of the top 3 memory consumers. The single largest consumer at that moment is named in the notification as the most likely contributor. This correlation — swap delta event + named culprit — is the core value of Bouncer's swap detection and is not replicated by any existing tool.

App Actions (Restart / Quit / Disable at Login)
All three user-facing actions use NSRunningApplication.terminate() as the first step — never SIGKILL. This triggers the app's normal quit flow, allowing it to save state and clean up. Using SIGKILL would risk data loss and generate negative reviews.

Restart: call terminate(), wait up to 3 seconds for the process to exit, then relaunch via NSWorkspace.shared.open(bundleURL). If the process has not exited after 3 seconds, show a warning rather than force-killing.

Quit: call terminate() only. No relaunch. The app stays out of memory until the user manually reopens it.

Disable at Login: call terminate(), then locate and disable the app's LaunchAgent plist in ~/Library/LaunchAgents/ using SMAppService.mainApp.unregister() where available, or by setting the Disabled key in the plist directly for older agents. Show a confirmation before executing — this is the most permanent of the three actions and should not be accidental.

6.4 Data Model

Samples Table
Records a memory snapshot for each running app every 30 seconds. Stores: pid, app name, bundle ID, memory in MB, and timestamp. Raw samples are retained for 7 days then purged automatically.

Baselines Table
Computed once per day per app. Stores: bundle ID, average memory (MB), 90th percentile memory (MB), and last updated timestamp. The p90 value is used for anomaly detection rather than the average, as it is more robust to occasional legitimate spikes.

6.5 Anomaly Detection Logic
An app is flagged as anomalous when ALL three conditions are true simultaneously:

Current memory exceeds the app's p90 baseline by more than 2.5x
Memory has been on an increasing trend for at least 30 minutes (positive slope via linear regression on samples)
System-level memory pressure is warning or critical (not normal)

A notification is sent only when the app has been anomalous for 10+ consecutive minutes AND no notification has been sent for that app in the past 24 hours.

6.6 Baseline Lifecycle & Learning Logic
Bouncer assigns each app its own independent baseline state. Rather than a binary "silent then active" model, Bouncer uses a progressive four-phase system that begins providing value within hours of installation while becoming more precise over time. The core principle: "learn while speaking, but speak with increasing precision."

Progressive Four-Phase Learning Model

Design Philosophy
A 3-day silent period before any alerts would cause users to uninstall Bouncer before it ever does anything. The solution is not to wait — it is to speak early with appropriate humility, tighten confidence as data accumulates, and always be transparent about which phase the app is in.


Phase
Threshold
Alert Sensitivity
Notes
Phase 1(0–4 hours)
4.0x Median
Extreme anomalies only
Very few samples. Median used (not mean) to resist startup spikes. Minimum 30 samples required before any alert. Notification tone: tentative.
Phase 2(4–24 hours)
3.0x Median
Significant anomalies
One partial usage cycle observed. Still uses Median. Thresholds tighten. Notification tone: cautious.
Phase 3(1–3 days)
2.5x P90
Standard detection
Multiple usage cycles. Switch from Median to P90 baseline. Full detection active. Notification tone: confident.
Active(3+ days)
2.5x P90
Full precision
Mature baseline. P90 is stable and representative. Notification tone: assertive.


Why Median, Not Mean, in Early Phases
In Phase 1 and Phase 2, Bouncer uses the Median rather than the Mean as the baseline reference point. This is a deliberate statistical choice: Mean is highly sensitive to outliers, and app startup behavior is full of them. An app that spikes to 3GB during initial cache loading then settles at 400MB will produce a severely inflated Mean, making the threshold too high to catch real anomalies. The Median is immune to these extremes and produces a far more accurate picture of normal behavior from limited samples.

Once enough data exists for a reliable P90 (Phase 3 onward), Bouncer switches to P90 as the baseline — it better captures the upper range of normal behavior than the Median does, reducing false positives from legitimate heavy usage peaks.

Minimum Sample Guard
Regardless of phase, Bouncer will never send a notification if fewer than 30 samples exist for that app. Thirty samples represents approximately 15 minutes of observation — the minimum needed to compute a statistically meaningful Median. Below this threshold, Bouncer may change the icon color as a soft signal but remains silent on notifications. This prevents false alerts in the first minutes after an app is first launched.

Confidence-Aware Notification Copy
Notification text adapts to the current phase, managing user expectations about alert precision. A Phase 1 alert that turns out to be a false positive should feel like "Bouncer is still learning" rather than "Bouncer is broken."

Phase
Notification Copy Style
Phase 1 & 2(learning tone)
"Bouncer is still learning Slack's habits, but its memory looks unusually high right now (2.1GB). Worth a look."
Phase 3 & Active(confident tone)
"Slack memory is abnormal. Currently using 2.1GB — 2.5x its normal level. Recommended: restart Slack."


New App Discovered After Day 3
When Bouncer encounters a bundle ID it has never seen before, it starts an independent Phase 1 learning period for that app only. All other already-monitored apps continue operating at their current phase. The new app is marked as "Learning" in the popover. Bouncer does not borrow a global default baseline — the false positive risk outweighs the benefit of immediate alerting.

App Version Change
A major update can significantly change an app's normal memory footprint. Bouncer reads CFBundleShortVersionString on every sample cycle. If the version string changes, that app's baseline is reset and it re-enters Phase 1. The user sees a one-time note in the popover: "Slack was updated — relearning memory profile."

Long-Dormant App Returns
If an app has not been observed for more than 30 days, its baseline is marked stale. When it reappears, Bouncer restarts from Phase 1 rather than relying on outdated data.

Baseline State Machine
State
Behavior
learning_phase_1
0–4 hours. Median baseline, 4x threshold, 30-sample minimum guard, tentative notification tone.
learning_phase_2
4–24 hours. Median baseline, 3x threshold, cautious notification tone.
learning_phase_3
1–3 days. P90 baseline, 2.5x threshold, confident notification tone.
active
3+ days. P90 baseline, 2.5x threshold, assertive notification tone. Full precision.
stale
Not seen in 30+ days. Resets to learning_phase_1 on next appearance.
ignored
User-added to ignore list. Sampled but never alerted. Reversible in settings.


AnomalyDetector Implementation Note
The detector reads the app's current state from the baselines table and selects the appropriate multiplier and baseline metric accordingly. This keeps detection logic fully decoupled from state management — each phase is independently testable with a fixed multiplier and a known dataset.

Data Model Update
The baselines table adds three fields: state (one of the six states above), version (last observed CFBundleShortVersionString for update detection), and sample_count (running total, used for the 30-sample minimum guard). The samples table is unchanged.

6.7 Performance Targets
Metric
Target
Idle RAM usage
< 20MB
Idle CPU usage
< 0.1% (between sampling cycles)
Sampling overhead
< 50ms per 30-second cycle
SQLite DB size (7 days)
< 15MB for typical user (20 apps, 30s sampling)
Popover open latency
< 100ms
Notification delivery
Within 60 seconds of anomaly confirmation


6.8 Permissions Required
Minimal Permissions
Bouncer requires only Accessibility permission to read process information from other apps. It does NOT require Screen Recording, Full Disk Access, or any network permissions. This is a deliberate design decision and a competitive advantage over tools like Bartender and Ice, which require Screen Recording permission.



7. Development Roadmap

7.1 MVP Scope (v1.0)
The v1.0 release focuses on one thing done excellently: detecting and resolving memory pressure caused by specific apps. Every feature that does not serve this goal is deferred.

Status
Feature
IN v1.0
Menu bar icon with 3-state color indicator
IN v1.0
Popover with per-app memory list ("Now" view)
IN v1.0
3-day learning period with baseline computation
IN v1.0
Anomaly detection engine (all 3 conditions)
IN v1.0
Smart notifications with "Restart Now" action button
IN v1.0
Three-action intervention: Restart, Quit, Disable at Login
IN v1.0
Swap detection: Orange alert state when macOS begins writing to SSD
IN v1.0
Swap notification: names top memory consumer at moment swap is triggered
IN v1.0
Menu bar display setting: off (default) / Memory Pressure % / RAM Used
IN v1.0
Ignore list for specific apps
IN v1.0
Sensitivity setting (3 levels)
IN v1.0
Launch at login
DEFERRED
History view and event timeline
DEFERRED
Weekly digest notifications
DEFERRED
Profiles (Work/Home/Focus mode)
DEFERRED
Dead agent / ghost process detection
DEFERRED
CLI companion tool
DEFERRED
AppleScript / Shortcuts integration
DEFERRED
Disk pressure monitoring


7.2 Development Timeline
Timeline
Milestone
Week 1–2
System Layer: Implement and validate proc_pid_rusage and host_statistics64 data collection. Confirm ri_phys_footprint accuracy against Activity Monitor.
Week 3
Data Layer: SQLite schema, GRDB integration, sampling timer, retention policy.
Week 4
Logic Layer: Baseline computation, anomaly detection, notification trigger conditions. Calibration on real hardware.
Week 5–6
UI Layer: NSStatusItem, NSPopover, settings window, UNUserNotificationCenter with action handlers.
Week 7
Integration and calibration: run on real machines for one full week. Tune anomaly thresholds to reduce false positives.
Week 8
Beta release to small group (~20 users). Collect feedback on notification frequency and accuracy.
Week 9–10
Fixes from beta feedback. App icon, onboarding flow, Sparkle update integration.
Week 11
Public launch.



8. Launch Strategy

8.1 Pricing
Launch price
$19 USD (one-time purchase)
Early adopter window
$14 for the first 200 buyers
No subscription
Never. This is a core brand promise.
No Mac App Store
Sandboxing restrictions prevent proc_pid_rusage access. Direct sale only via website + Paddle/Gumroad.
No freemium
Free trials with a 14-day trial period instead. Full features, no crippling.


8.2 Primary Launch Channels

r/macapps (Highest Priority)
The r/macapps subreddit is where the target audience lives and actively discovers new tools. The launch post should lead with a real screenshot — not a marketing mockup — showing Bouncer's popover with an actual memory anomaly detected. The headline: "I got tired of guessing which app was killing my RAM, so I built something that tells you directly." This authentic framing typically outperforms polished product announcements in this community.

Hacker News (Show HN)
A Show HN post focusing on the technical approach: the use of ri_phys_footprint vs. resident_size, the baseline computation methodology, and the Apple Silicon unified memory angle. HN readers respond to technical depth and honest discussion of trade-offs.

Product Hunt
Schedule for a Tuesday or Wednesday launch. Focus the gallery on the notification interaction — show the exact moment a notification fires with the Restart button. This is the most distinctive interaction and most shareable moment.

8.3 Positioning Statement
Do not position Bouncer as a "menu bar manager" — that category is owned by Bartender and Ice. Position it as a "memory first responder" or "RAM watchdog." The comparison should always be to Activity Monitor, not to Bartender. This keeps the competitive frame on a tool Bouncer genuinely improves upon, rather than on tools where Bouncer offers only marginal differentiation.

8.4 Success Metrics (90 Days Post-Launch)
500+ paid licenses
< 3% refund rate
Notification accuracy > 85% (users click "Restart" rather than "Ignore")
Retention: > 60% of users still running Bouncer after 30 days


9. Risks & Mitigations

Risk
Likelihood
Description
Mitigation
macOS API changes
High
Apple changes proc_pid_rusage or restricts process inspection in a future OS update
Monitor developer betas. Build abstraction layer around system APIs so alternative data sources can be substituted.
False positive alerts
High
Users get notified about apps that are "normal" heavy memory users (Xcode, browsers)
Default ignore list for known heavy apps. 3-condition requirement before alerting. User-configurable sensitivity. 10-minute persistence requirement.
Self-defeating footprint
Medium
Bouncer itself consumes significant memory, undermining its purpose
Hard performance budget: < 20MB RAM. Instrument and enforce in CI. Make Bouncer's own memory usage visible in its own UI.
Sandboxing pressure
Medium
Apple moves toward requiring Mac App Store distribution with sandboxing
Direct distribution is already planned. Monitor policy changes. Sparkle handles updates without the App Store.
Market size
Low-Medium
The addressable market (memory-constrained Mac users who will pay) is smaller than estimated
8GB MacBooks are Apple's best-selling Macs. This is a large and growing segment.



10. Open Questions for v1

The following decisions are intentionally deferred and should be resolved during the beta period:

Should Bouncer monitor disk pressure in addition to memory pressure in v1, or strictly scope to RAM?
What is the right default sensitivity level? Conservative (fewer alerts) vs. Aggressive (catches more issues)?
Should the learning period be 3 days or 5 days? Longer period = better baselines but delayed value.
Is a 14-day free trial the right conversion mechanism, or is a limited-feature free tier more effective for this category?
Should the app name be "Bouncer" or something more neutral? Bouncer implies the management layer more than the diagnostic layer.




End of Document
Bouncer  |  v1.0  |  April 2026
