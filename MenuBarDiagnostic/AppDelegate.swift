import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hudWindow: HUDWindow?
    let monitor = ProcessMonitor()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stopMonitoring()
    }

    private func setupPopover() {
        let vc = NSHostingController(rootView: StatusMenuView(monitor: monitor))
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
            let hud = HUDWindow(monitor: monitor)
            hud.center()
            hud.makeKeyAndOrderFront(nil)
            hudWindow = hud
        }
    }
}
