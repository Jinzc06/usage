import SwiftUI

struct DonutChart: View {
    var fractions: [(color: Color, fraction: Double)]
    var center: String
    var note: String?

    var body: some View {
        ZStack {
            ring
            VStack(spacing: 1) {
                Text(center)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.clay)
                        .lineLimit(1)
                }
            }
            .frame(width: 78)
        }
        .frame(width: 124, height: 124)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(center)
    }

    private var ring: some View {
        Canvas { context, size in
            let lineWidth: CGFloat = 16
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - lineWidth / 2
            var track = Path()
            track.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.stroke(track, with: .color(Palette.track), lineWidth: lineWidth)

            let visible = fractions.filter { $0.fraction > 0 }
            guard !visible.isEmpty else { return }
            if visible.count == 1, let only = visible.first {
                context.stroke(track, with: .color(only.color), lineWidth: lineWidth)
                return
            }
            let gap = 3.0
            let sweepBudget = 360.0 - gap * Double(visible.count)
            var angle = -90.0
            for segment in visible {
                let sweep = max(sweepBudget * segment.fraction, 0)
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(angle),
                    endAngle: .degrees(angle + sweep),
                    clockwise: false
                )
                context.stroke(
                    path,
                    with: .color(segment.color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
                angle += sweep + gap
            }
        }
    }
}
