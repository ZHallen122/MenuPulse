# Contributing to Bouncer

## Prerequisites

- macOS 13 Ventura or later
- Xcode 15+

## Clone and build

```bash
git clone https://github.com/ZHallen122/MenuPulse
cd MenuPulse
```

Command-line build:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Bouncer.xcodeproj" \
           -scheme "Bouncer" \
           -configuration Debug build
```

Or open in Xcode, select the **Bouncer** scheme, and press **⌘R**.

## Run tests

The `"Bouncer"` scheme is not configured for testing. Use the dedicated test scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Bouncer.xcodeproj" \
           -scheme "BouncerTests" \
           -configuration Debug test
```

All tests must pass before submitting a PR.

## Code style

- **Language**: Swift / SwiftUI. Keep UI in SwiftUI; use AppKit only where required (`NSStatusItem`, `NSPopover`, `NSWindow`).
- **No forced unwraps** without an inline comment explaining why the value is guaranteed non-nil.
- **Runtime errors**: use `NSLog` (not `print`) for errors that operators or crash reports need to surface.
- **No silent failures**: every `sqlite3_prepare_v2`, bind, or step call that can fail must log on failure before returning.
- Follow the existing file structure. See [README.md](README.md#key-files) for the layer overview and [ARCHITECTURE.md](ARCHITECTURE.md) for layer boundaries and where to place new files.

## Submitting a PR

1. Fork the repo and create a feature branch (`git checkout -b feat/my-change`).
2. Make your changes and ensure all tests pass.
3. Open a pull request against `main` with a clear description of what changed and why.
4. Keep PRs focused — one logical change per PR.
