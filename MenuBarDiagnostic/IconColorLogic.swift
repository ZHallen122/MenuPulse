import AppKit

/// Pure icon-color computation extracted for unit testing (no NSStatusItem required).
///
/// Priority: red (swap rapid growth) → orange (swap active or unacknowledged anomaly alert) → green.
func iconColor(swapState: SwapState, pendingAnomalyAlert: Bool) -> NSColor {
    switch swapState {
    case .rapidGrowth: return .systemRed
    case .active:      return .systemOrange
    case .none:        return pendingAnomalyAlert ? .systemOrange : .systemGreen
    }
}
