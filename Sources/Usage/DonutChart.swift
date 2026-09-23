import Observation
import SwiftUI

@MainActor
@Observable
final class ChartHover {
    var name: String?
    var x: CGFloat = 0
    var y: CGFloat = 0
}

struct DonutSlice: Identifiable {
    var name: String
    var color: Color
    var fraction: Double
    var label: String
    var id: String { name }
}

struct DonutChart: View {
    var slices: [DonutSlice]
    var center: String
    var hover: ChartHover

    private let side: CGFloat = 124
    private let lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            ring
            Text(center)
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .frame(width: 78)
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                apply(tip(at: location))
            case .ended:
                hover.name = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let name = hover.name, let slice = slices.first(where: { $0.name == name }) {
                tipView(slice)
                    .offset(x: hover.x, y: hover.y)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(center)
    }

    private var ring: some View {
        Canvas { context, size in
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
            for arc in DonutHit.arcs(slices) {
                var path = Path()
                if arc.sweep >= 359 {
                    path.addEllipse(in: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    context.stroke(path, with: .color(arc.color), lineWidth: lineWidth)
                } else {
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(arc.start),
                        endAngle: .degrees(arc.start + arc.sweep),
                        clockwise: false
                    )
                    context.stroke(
                        path,
                        with: .color(arc.color),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                }
            }
        }
    }

    private func tip(at location: CGPoint) -> (name: String, x: CGFloat, y: CGFloat)? {
        guard let name = DonutHit.hit(slices, at: location, side: side, lineWidth: lineWidth) else { return nil }
        return (
            name,
            min(max(location.x - 36, -8), side - 88),
            location.y < side * 0.45 ? location.y + 14 : location.y - 46
        )
    }

    private func apply(_ tip: (name: String, x: CGFloat, y: CGFloat)?) {
        guard let tip else {
            hover.name = nil
            return
        }
        hover.name = tip.name
        hover.x = tip.x
        hover.y = tip.y
    }

    private func tipView(_ slice: DonutSlice) -> some View {
        let percent = Int((slice.fraction * 100).rounded())
        return HStack(spacing: 6) {
            Circle()
                .fill(slice.color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(slice.label) · \(percent)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
    }
}

enum DonutHit {
    struct Arc {
        var name: String
        var color: Color
        var start: Double
        var sweep: Double
    }

    static func arcs(_ slices: [DonutSlice]) -> [Arc] {
        let visible = slices.filter { $0.fraction > 0 }
        guard !visible.isEmpty else { return [] }
        if visible.count == 1 {
            return [Arc(name: visible[0].name, color: visible[0].color, start: -90, sweep: 360)]
        }
        let gap = 3.0
        let budget = 360.0 - gap * Double(visible.count)
        var angle = -90.0
        return visible.map { slice in
            let sweep = max(budget * slice.fraction, 0)
            let arc = Arc(name: slice.name, color: slice.color, start: angle, sweep: sweep)
            angle += sweep + gap
            return arc
        }
    }

    static func hit(_ slices: [DonutSlice], at location: CGPoint, side: CGFloat, lineWidth: CGFloat) -> String? {
        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = side / 2 - lineWidth / 2
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= radius - lineWidth / 2 - 3, distance <= radius + lineWidth / 2 + 3 else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi
        while degrees < -90 { degrees += 360 }
        while degrees >= 270 { degrees -= 360 }
        for arc in arcs(slices) {
            let end = arc.start + arc.sweep
            if degrees >= arc.start, degrees <= end { return arc.name }
        }
        return nil
    }
}
