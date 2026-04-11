import AppKit

/// Pure icon-color computation extracted for unit testing (no NSStatusItem required).
///
/// Priority: swapCritical → red, swapSignificant → orange, swapMinor/compressedGrowing → yellow,
/// normal with pending anomaly → orange, normal → green.
func iconColor(swapState: SwapState, pendingAnomalyAlert: Bool) -> NSColor {
    switch swapState {
    case .swapCritical:       return .systemRed
    case .swapSignificant:    return .systemOrange
    case .swapMinor:          return .systemYellow
    case .compressedGrowing:  return .systemYellow
    case .normal:             return pendingAnomalyAlert ? .systemOrange : .systemGreen
    }
}
