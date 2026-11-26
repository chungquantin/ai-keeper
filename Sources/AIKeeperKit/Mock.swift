import SwiftUI

// Sample data for the screens whose measurements do not exist yet (traces, speed, reliability, advisor, hooks, budgets per tool).
// Every screen that shows it carries a "Sample data" chip, so nothing here is mistaken for the user's own numbers.

enum MockData {
    static let monthlySavings = 64
    static func seeded(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }
    static func series(_ n: Int, _ k: Int, base: Double = 0.5, spread: Double = 0.35, drift: Double = 0) -> [Double] {
        (0..<n).map { max(0.04, min(1, base + drift * Double($0) + (seeded($0, k) - 0.5) * spread * 2)) }
    }
}

enum AgentColor {
    static let claude = Color.dynamic(light: 0x2F45FF, dark: 0x6E7DFF)
    static let codex = Color.dynamic(light: 0x0EA5A0, dark: 0x2DD4BF)
    static let conductor = Color.dynamic(light: 0x7C3AED, dark: 0xB794F6)
    static let superset = Color.dynamic(light: 0xDB2777, dark: 0xF472B6)
    static let pi = Color.dynamic(light: 0x8E8E93, dark: 0xA1A1A6)
    static let good = Color.dynamic(light: 0x127A3E, dark: 0x4ADE80)
    static func of(_ name: String) -> Color {
        switch name.lowercased() {
        case "claude", "claude code": claude
        case "codex": codex
        case "conductor": conductor
        case "superset": superset
        default: pi
        }
    }
}

// MARK: Chips and cards

struct SampleChip: View {
    var text = "Sample data"
    var body: some View {
        Text(text).font(.brand(11, .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Brand.muted, in: Capsule())
            .foregroundStyle(Brand.mutedForeground)
            .help("These numbers are examples. This feature is not measured yet.")
    }
}

enum Tone { case blue, amber, red, violet, gray, green
    var fg: Color {
        switch self {
        case .blue: Brand.primaryText
        case .amber: Brand.reclaimText
        case .red: Brand.destructive
        case .violet: Brand.merged
        case .gray: Brand.mutedForeground
        case .green: AgentColor.good
        }
    }
    var bg: Color {
        switch self {
        case .blue: Brand.primaryTint
        case .amber: Brand.reclaimTint
        case .red: Brand.destructiveTint
        case .violet: Brand.merged.opacity(0.12)
        case .gray: Brand.muted
        case .green: AgentColor.good.opacity(0.14)
        }
    }
}

struct Tag: View {
    let text: String
    var tone: Tone = .gray
    var body: some View {
        Text(text).font(.brand(11, .medium)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.bg, in: Capsule()).foregroundStyle(tone.fg)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).panel()
    }
}

struct CardTitle: View {
    let title: String
    var note: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.bHeadline)
            Spacer()
            if let note { Text(note).font(.bCaption).foregroundStyle(.secondary) }
        }
    }
}

/// A scrolling page with the standard margins and, optionally, the page header from the design:
/// the page's name, one line saying what it is for, and its main action. It also tells its children how wide it is.
struct Page<Content: View>: View {
    var title: String?
    var subtitle: String?
    var action: String?
    var sample = false
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.horizontal, geo.size.width < 760 ? 16 : 28).padding(.vertical, 16)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.pageWidth, geo.size.width)
        }
    }
}

struct FilterPills: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { t in
                HStack(spacing: 6) { Text(t) }
                    .font(.brand(12, .medium)).padding(.horizontal, 10).frame(height: 28)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.border))
            }
            Spacer()
        }
    }
}

struct Delta: View {
    let text: String
    var good: Bool?
    var body: some View {
        let tone: Tone = good == nil ? .gray : (good! ? .green : .red)
        Text(text).font(.brand(11, .semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tone.bg, in: Capsule()).foregroundStyle(tone.fg)
    }
}

struct KPI: View {
    let title: String
    let value: String
    var prior: String?
    var delta: String?
    var good: Bool?
    var spark: [Double]?
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Text(title).font(.bCaption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                if let delta { Delta(text: delta, good: good).fixedSize() }
            }
            Text(value).font(.brand(26, .semibold)).kerning(-0.6).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(prior ?? " ").font(.bCaption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if let spark { Spark(values: spark, color: good == false ? Brand.destructive : (good == true ? AgentColor.good : Brand.accent)).frame(height: 30).padding(.top, 6) }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, spark == nil ? 14 : 0)
        .frame(maxWidth: .infinity, minHeight: spark == nil ? 92 : 124, maxHeight: .infinity, alignment: .topLeading).clipped()
        .panel()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent, lineWidth: selected ? 2 : 0))
    }
}

struct KPIRow: View {
    let items: [KPI]
    /// Wraps to a second line when the window is narrow, so a tile never has to truncate its number.
    var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) { ForEach(items.indices, id: \.self) { items[$0] } } }
}

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

/// A grid of squares, shaded by value (0...1).
struct Heatgrid: View {
    let rows: [[Double]]
    var color: Color = Brand.accent
    var cell: CGFloat = 16
    var body: some View {
        VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color.opacity(0.06 + 0.84 * rows[r][c])).frame(maxWidth: .infinity).frame(height: cell)
                    }
                }
            }
        }.accessibilityHidden(true)
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

/// A row in a list card: leading marker, two lines of text, optional trailing pieces.
struct ListRow<Lead: View, Trail: View>: View {
    let title: String
    var subtitle: String?
    var selected = false
    @ViewBuilder var lead: Lead
    @ViewBuilder var trail: Trail
    var body: some View {
        HStack(spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.bBody.weight(.medium)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trail
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(selected ? Brand.primaryTint : .clear)
    }
}

struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { it in
                row(it)
                if it.id != items.last?.id { Divider().padding(.leading, 16) }
            }
        }
    }
}

/// A single line of advice, set on a muted ground.
struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(.bCaption).foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Dot: View {
    let tone: Tone
    var body: some View { Circle().fill(tone == .gray ? Brand.mutedForeground.opacity(0.4) : tone.fg).frame(width: 7, height: 7) }
}

extension Sequence where Element == SessionInfo {
    /// The `k` most recently active sessions in one pass: O(n), not the O(n log n) of sorting everything to read eight rows.
    func newest(_ k: Int) -> [SessionInfo] {
        var top: [SessionInfo] = []; top.reserveCapacity(k + 1)
        for s in self {
            if top.count == k, let last = top.last, s.last <= last.last { continue }
            let i = top.firstIndex { s.last > $0.last } ?? top.count
            top.insert(s, at: i)
            if top.count > k { top.removeLast() }
        }
        return top
    }
}

/// The segmented control from the design: a muted track, and the chosen segment raised in white. Never cobalt, so it does not compete with data.
struct Seg<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    init(_ options: [(String, T)], selection: Binding<T>) { self.options = options; _selection = selection }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].1 == selection
                Button { selection = options[i].1 } label: {
                    Text(options[i].0).font(.brand(12, .medium)).foregroundStyle(on ? Color.primary : Brand.mutedForeground)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.card)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.edge))
                                .shadow(color: Brand.liftNear, radius: 1, y: 1) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).background(Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).fixedSize()
    }
}

/// A filter pill that opens a menu: "Last 30 days", "All agents".
struct PillMenu<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    init(_ options: [(String, T)], selection: Binding<T>) { self.options = options; _selection = selection }
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in Button(options[i].0) { selection = options[i].1 } }
        } label: {
            Text(options.first { $0.1 == selection }?.0 ?? "").font(.brand(12, .medium)).foregroundStyle(Color.primary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.border))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
