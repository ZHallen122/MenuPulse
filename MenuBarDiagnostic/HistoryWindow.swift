import AppKit
import SwiftUI

/// Standalone window that hosts the History view.
///
/// Opened from the Popover's "View History" footer button.
/// The window is retained by `AppDelegate` and reused on subsequent opens
/// rather than re-created, so the user's scroll position and selected
/// entry are preserved across opens.
final class HistoryWindow: NSWindow {

    init(dataStore: DataStore) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "History"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 500, height: 400)
        contentView = NSHostingView(rootView: HistoryView(dataStore: dataStore))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
