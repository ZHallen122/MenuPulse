import AppKit
import SwiftUI
import Combine
import UserNotifications
import ServiceManagement

/// Central application delegate for Bouncer.
///
/// Owns the `NSStatusItem` (menu bar icon) and `NSPopover` (process list HUD), and wires
/// together `ProcessMonitor`, `AnomalyDetector`, and `SwapMonitor`. Responsibilities include:
/// - Registering `UNUserNotificationCenter` categories (`MEMORY_ANOMALY`, `SWAP_ACTIVE`) and
///   handling notification responses (Restart Now, Ignore, Quit Top App, View All, Dismiss).
/// - Driving the icon tint: red (swap rapid growth) → orange (swap active or unacknowledged
///   anomaly alert) → green (all clear).
/// - Managing the settings window lifecycle (single-instance, re-use on re-open).
/// - Applying and observing the launch-at-login preference via `SMAppService`.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hudWindow: HUDWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    var pendingAnomalyAlert = false

    let prefs = PreferencesManager()
    lazy var monitor: ProcessMonitor = ProcessMonitor(prefs: prefs)
    lazy var anomalyDetector: AnomalyDetector = AnomalyDetector(dataStore: monitor.dataStore, prefs: prefs)
    lazy var swapMonitor = SwapMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: "Bouncer")
            button.imagePosition = .imageLeft
            button.action = #selector(handleStatusBarClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }

        setupPopover()
        setupNotifications()
        monitor.startMonitoring()
        swapMonitor.startMonitoring()
        swapMonitor.topProcessProvider = { [weak self] in self?.monitor.processes ?? [] }

        // Update menu bar title: show RAM % when enabled, otherwise blank.
        Publishers.CombineLatest(monitor.$systemRAMUsedBytes, monitor.$systemRAMTotalBytes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateMenuBarTitle() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .filter { _ in UserDefaults.standard.object(forKey: "showMemoryPressureInMenuBar") != nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarTitle() }
            .store(in: &cancellables)

        // Launch at login — apply stored value on launch, then observe UserDefaults changes
        applyLaunchAtLogin(prefs.launchAtLogin)
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: "launchAtLogin") }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.applyLaunchAtLogin(enabled)
            }
            .store(in: &cancellables)

        // Update icon tint: Red (swap rapid growth) > Orange (swap active or pending anomaly) > Green.
        Publishers.CombineLatest(swapMonitor.$swapState, anomalyDetector.$anomalousBundleIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, anomalousBundleIDs in
                guard let self else { return }
                if !anomalousBundleIDs.isEmpty {
                    self.pendingAnomalyAlert = true
                } else {
                    self.pendingAnomalyAlert = false
                }
                self.updateIconTint()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stopMonitoring()
        swapMonitor.stopMonitoring()
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()

        // Request permission to show alerts and play sounds.
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Bouncer: notification authorization error: %@", error.localizedDescription)
            } else if !granted {
                NSLog("Bouncer: notification permission denied by user")
            }
        }

        // Register the "MEMORY_ANOMALY" category with Restart Now and Ignore actions.
        let restartAction = UNNotificationAction(
            identifier: "RESTART_NOW",
            title: "Restart Now",
            options: .foreground
        )
        let ignoreAction = UNNotificationAction(
            identifier: "IGNORE",
            title: "Ignore",
            options: []
        )
        let memoryAnomalyCategory = UNNotificationCategory(
            identifier: "MEMORY_ANOMALY",
            actions: [restartAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )

        // Register the "SWAP_ACTIVE" category with swap-specific actions.
        let quitTopAppAction = UNNotificationAction(
            identifier: "QUIT_TOP_APP",
            title: "Quit Top App",
            options: .foreground
        )
        let viewAllAction = UNNotificationAction(
            identifier: "VIEW_ALL",
            title: "View All",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )
        let swapActiveCategory = UNNotificationCategory(
            identifier: "SWAP_ACTIVE",
            actions: [quitTopAppAction, viewAllAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([memoryAnomalyCategory, swapActiveCategory])

        // Wire the shared anomaly detector into the process monitor.
        monitor.anomalyDetector = anomalyDetector
    }

    private func setupPopover() {
        let vc = NSHostingController(rootView: StatusMenuView(
            monitor: monitor,
            prefs: prefs,
            anomalyDetector: anomalyDetector,
            swapMonitor: swapMonitor,
            onSettingsTap: { [weak self] in self?.openSettings() },
            onClosePopover: { [weak self] in self?.popover?.performClose(nil) }
        ))
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: 300, height: 400)
        pop.behavior = .transient
        self.popover = pop
    }

    func openSettings() {
        // Re-use an existing window if it's still open.
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let vc = NSHostingController(rootView: SettingsView(prefs: prefs, anomalyDetector: anomalyDetector))
        let win = NSWindow(contentViewController: vc)
        win.title = "Bouncer Settings"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        // Prevent NSWindow from releasing itself on close (fixes EXC_BAD_ACCESS on reopen).
        // Swift ARC manages the lifetime via settingsWindow; the ObjC object must not
        // self-release underneath it.
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 400, height: 300)
        // NSHostingController sizes the window to fit SwiftUI content automatically.
        win.center()
        settingsWindow = win
        NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification, object: win)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsWindow = nil }
            .store(in: &cancellables)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleStatusBarClick(_ sender: AnyObject?) {
        let isOptionHeld = NSEvent.modifierFlags.contains(.option)
        if isOptionHeld {
            toggleHUD()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            pendingAnomalyAlert = false
            updateIconTint()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIconTint() {
        statusItem?.button?.contentTintColor = iconColor(
            swapState: swapMonitor.swapState,
            pendingAnomalyAlert: pendingAnomalyAlert
        )
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SMAppService error: %@", error.localizedDescription)
        }
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem?.button else { return }
        if prefs.showMemoryPressureInMenuBar {
            let used = monitor.systemRAMUsedBytes
            let total = monitor.systemRAMTotalBytes
            button.title = total > 0 ? "\(Int((Double(used) / Double(total) * 100).rounded()))%" : ""
        } else {
            button.title = ""
        }
    }

    private func toggleHUD() {
        if let hud = hudWindow {
            if hud.isVisible {
                hud.orderOut(nil)
            } else {
                hud.makeKeyAndOrderFront(nil)
            }
        } else {
            let hud = HUDWindow(monitor: monitor, prefs: prefs)
            hud.center()
            hud.makeKeyAndOrderFront(nil)
            hudWindow = hud
        }
    }
}
