import SwiftUI

// Small charts and their legend.

// MARK: Charts (drawn, no dependencies)

struct Spark: View {
    let values: [Double]
    var color: Color = Brand.accent
    var body: some View {
        GeometryReader { g in
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: g.size.height * (1 - CGFloat(v)) * 0.8 + 3)
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 1.75, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

/// Days across, one stack per day. `data[day][series]` are fractions of the tallest day.
struct StackedBars: View {
    let data: [[Double]]
    let colors: [Color]
    var height: CGFloat = 120
    var body: some View {
        let tallest = max(data.map { $0.reduce(0, +) }.max() ?? 1, 0.001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(data.indices, id: \.self) { d in
                VStack(spacing: 1) {
                    ForEach((0..<data[d].count).reversed(), id: \.self) { s in
                        Rectangle().fill(colors[s % colors.count]).frame(height: max(1, height * CGFloat(data[d][s] / tallest)))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 2)).frame(maxWidth: .infinity)
            }
        }.frame(height: height, alignment: .bottom).accessibilityHidden(true)
    }
}

struct LineChart: View {
    struct Line { let values: [Double]; let color: Color; var dashed = false; var width: CGFloat = 2 }
    let lines: [Line]
    var height: CGFloat = 150
    var events: [Double] = []   // 0...1 across the width
    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach([0.2, 0.5, 0.8], id: \.self) { f in
                    Path { p in p.move(to: CGPoint(x: 0, y: g.size.height * f)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * f)) }
                        .stroke(Brand.border, lineWidth: 1)
                }
                ForEach(events, id: \.self) { e in
                    Path { p in p.move(to: CGPoint(x: g.size.width * e, y: 4)); p.addLine(to: CGPoint(x: g.size.width * e, y: g.size.height - 4)) }
                        .stroke(Brand.reclaim, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
                ForEach(lines.indices, id: \.self) { li in
                    let l = lines[li]
                    Path { p in
                        for (i, v) in l.values.enumerated() {
                            let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(l.values.count - 1, 1)), y: g.size.height * (1 - CGFloat(v)) * 0.9 + 6)
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                    }.stroke(l.color.opacity(l.dashed ? 0.5 : 1), style: StrokeStyle(lineWidth: l.width, lineJoin: .round, dash: l.dashed ? [5, 4] : []))
                }
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

struct HBar: View {
    let label: String
    var value: String = ""
    let fraction: Double
    var color: Color = Brand.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Circle().fill(color).frame(width: 8, height: 8); Text(label).font(.bBody.weight(.medium)); Spacer(); Text(value).font(.bCaption).foregroundStyle(.secondary).monospacedDigit() }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.muted)
                    Capsule().fill(color).frame(width: max(4, g.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }.frame(height: 6)
        }
    }
}

struct Legend: View {
    let items: [(String, Color)]
    var body: some View {
        FlowLayout(spacing: 14, lineSpacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) { Circle().fill(items[i].1).frame(width: 7, height: 7); Text(items[i].0).foregroundStyle(.secondary).fixedSize() }
            }
        }.font(.bCaption)
    }
}
