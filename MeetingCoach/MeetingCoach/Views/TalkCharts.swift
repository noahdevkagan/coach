import SwiftUI

/// Talk-share line chart shared by the transcript-header sparkline and the
/// dashboard's per-session trend: normalized points with the warn level as
/// a faint reference line. One chart, one threshold — the surfaces must
/// never disagree about where "too much talking" starts.
struct ShareTrendLine: View {
    /// (x, share) pairs; x is any monotonically increasing value
    /// (elapsed seconds, timeIntervalSinceReferenceDate, …).
    let points: [(x: Double, share: Double)]
    var warnAt: Double = TalkStats.warnShare
    var showDots = false

    var body: some View {
        GeometryReader { geo in
            let minX = points.first?.x ?? 0
            let maxX = max(points.last?.x ?? 1, minX + 1)
            let cgPoints = points.map { point in
                CGPoint(
                    x: geo.size.width * (point.x - minX) / (maxX - minX),
                    y: geo.size.height * (1 - point.share)
                )
            }
            ZStack {
                Path { p in
                    let y = geo.size.height * (1 - warnAt)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(Color.orange.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    guard let first = cgPoints.first else { return }
                    p.move(to: first)
                    for pt in cgPoints.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.blue.opacity(0.7), lineWidth: 1.5)

                if showDots {
                    ForEach(Array(cgPoints.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 4, height: 4)
                            .position(pt)
                    }
                }
            }
        }
    }
}
