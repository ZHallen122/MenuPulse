import SwiftUI

struct RAMBarView: View {
    let bytes: UInt64
    let maxBytes: UInt64

    private var fraction: Double {
        min(Double(bytes) / Double(maxBytes), 1.0)
    }

    private var barColor: Color {
        switch fraction {
        case ..<0.4:  return .green
        case ..<0.7:  return .yellow
        case ..<0.9:  return .orange
        default:      return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(barColor)
                    .frame(width: max(geo.size.width * fraction, 2))
            }
        }
    }
}
