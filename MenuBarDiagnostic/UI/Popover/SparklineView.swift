import SwiftUI

/// A SwiftUI view that renders a rolling memory or CPU trend as a filled area chart with a gradient.
///
/// Values are normalized relative to the visible maximum so the chart always fills the available
/// height. When fewer than 2 data points are available, a placeholder rectangle is shown instead.
struct SparklineView: View {
    let values: [Double]
    var color: Color = .blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Background fill
                if values.count >= 2 {
                    fillPath(in: geo.size)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [color.opacity(0.25), color.opacity(0.0)]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(in: geo.size)
                        .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .cornerRadius(2)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let maxVal = max(values.max() ?? 0.01, 0.01)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, val in
            CGPoint(
                x: CGFloat(i) * step,
                y: size.height - CGFloat(val / maxVal) * size.height
            )
        }
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        let pts = points(in: size)
        guard let first = pts.first else { return path }
        path.move(to: first)
        pts.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }

    private func fillPath(in size: CGSize) -> Path {
        var path = Path()
        let pts = points(in: size)
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.x, y: size.height))
        path.addLine(to: first)
        pts.dropFirst().forEach { path.addLine(to: $0) }
        if let last = pts.last {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
        }
        path.closeSubpath()
        return path
    }
}
