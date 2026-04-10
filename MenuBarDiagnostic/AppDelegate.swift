import AppKit
import SwiftUI
import Combine
import UserNotifications
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hudWindow: HUDWindow?
    private var cancellables = Set<AnyCancellable>()

    let prefs = PreferencesManager()
    lazy var monitor: ProcessMonitor = ProcessMonitor(prefs: prefs)
    lazy var anomalyDetector: AnomalyDetector = AnomalyDetector(dataStore: monitor.dataStore, prefs: prefs)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: "Menu Bar Diagnostic")
            button.imagePosition = .imageLeft
            button.action = #selector(handleStatusBarClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }

        setupPopover()
        setupNotifications()
        monitor.startMonitoring()

        // No badge — icon color conveys status
        monitor.$processes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.statusItem?.button?.title = ""
            }
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

        // Update icon tint color to reflect system memory pressure.
        monitor.$memoryPressure
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pressure in
                let color: NSColor
                switch pressure {
                case .normal:   color = .systemGreen
                case .warning:  color = .systemOrange
                case .critical: color = .systemRed
                }
                self?.statusItem?.button?.contentTintColor = color
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stopMonitoring()
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()

        // Request permission to show alerts and play sounds.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
        let category = UNNotificationCategory(
            identifier: "MEMORY_ANOMALY",
            actions: [restartAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        // Wire the shared anomaly detector into the process monitor.
        monitor.anomalyDetector = anomalyDetector
    }

    private func setupPopover() {
        let vc = NSHostingController(rootView: StatusMenuView(monitor: monitor, prefs: prefs, anomalyDetector: anomalyDetector))
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: 300, height: 400)
        pop.behavior = .transient
        self.popover = pop
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
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
