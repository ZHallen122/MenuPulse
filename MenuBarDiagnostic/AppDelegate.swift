import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hudWindow: HUDWindow?
    private var cancellables = Set<AnyCancellable>()

    let prefs = PreferencesManager()
    lazy var monitor: ProcessMonitor = ProcessMonitor(prefs: prefs)

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
        monitor.startMonitoring()

        // Update badge with process count after each sample
        monitor.$processes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                self?.statusItem?.button?.title = processes.isEmpty ? "" : "\(processes.count)"
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

    private func setupPopover() {
        let vc = NSHostingController(rootView: StatusMenuView(monitor: monitor, prefs: prefs))
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: 320, height: 400)
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
