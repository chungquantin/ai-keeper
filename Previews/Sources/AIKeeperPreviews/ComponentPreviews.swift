import SwiftUI
@testable import AIKeeperKit

private struct Swatch: View {
    let name: String; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color).frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.border))
            Text(name).font(.bCaption)
        }.frame(width: 110)
    }
}

#Preview("Brand colours") {
    let tokens: [(String, Color)] = [
        ("background", Brand.background), ("card", Brand.card), ("muted", Brand.muted), ("border", Brand.border), ("accent", Brand.accent),
        ("primaryTint", Brand.primaryTint), ("reclaim", Brand.reclaim), ("reclaimTint", Brand.reclaimTint), ("merged", Brand.merged),
        ("destructive", Brand.destructive), ("claude", AgentColor.claude), ("codex", AgentColor.codex), ("conductor", AgentColor.conductor),
        ("superset", AgentColor.superset), ("pi", AgentColor.pi)]
    return LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 14), count: 5), spacing: 14) {
        ForEach(tokens, id: \.0) { Swatch(name: $0.0, color: $0.1) }
    }.padding(24).background(Brand.background)
}

#Preview("Buttons and tags") {
    VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 10) {
            Button("Clean 64 GB") {}.buttonStyle(.brandProminent).controlSize(.large)
            Button("Review") {}.controlSize(.large)
            Button("Remove") {}.buttonStyle(.brandProminent).tint(Brand.destructive).controlSize(.large)
            Button("Small") {}.controlSize(.small)
        }
        HStack(spacing: 8) {
            Tag(text: "Merged", tone: .violet); Tag(text: "Open", tone: .blue); Tag(text: "Needs you", tone: .amber)
            Tag(text: "Failed", tone: .red); Tag(text: "Idle", tone: .gray); Tag(text: "Healthy", tone: .green); SampleChip()
        }
        HStack(spacing: 8) { Delta(text: "−14%", good: true); Delta(text: "+1.3 pts", good: false); Delta(text: "+3") }
    }.padding(24).background(Brand.background).tint(Brand.accent)
}

#Preview("Cards and tiles") {
    VStack(alignment: .leading, spacing: 14) {
        KPIRow(items: [
            KPI(title: "Failed tool calls", value: "10.4%", prior: "vs. 9.1% prior", delta: "+1.3 pts", good: false),
            KPI(title: "Retries per task", value: "1.8", prior: "vs. 2.1 prior", delta: "−14%", good: true),
            KPI(title: "Time to first edit", value: "4.8 min", delta: "−30%", good: true, spark: MockData.series(12, 1)),
        ])
        Card { VStack(alignment: .leading, spacing: 8) { CardTitle(title: "A card", note: "with a note"); Note(text: "A line of advice on a muted ground.") } }
    }.padding(24).frame(width: 760).background(Brand.background)
}

#Preview("Charts") {
    VStack(alignment: .leading, spacing: 18) {
        Card { VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "StackedBars")
            StackedBars(data: (0..<30).map { d in (0..<3).map { k in 0.1 + MockData.seeded(d, k) } }, colors: [AgentColor.claude, AgentColor.codex, AgentColor.conductor])
            Legend(items: [("Claude Code", AgentColor.claude), ("Codex", AgentColor.codex), ("Conductor", AgentColor.conductor)])
        } }
        Card { VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "LineChart")
            LineChart(lines: [.init(values: MockData.series(40, 2), color: AgentColor.claude, dashed: true, width: 1.5), .init(values: MockData.series(40, 3), color: AgentColor.claude)], events: [0.3, 0.7])
        } }
        HStack(spacing: 14) {
            Card { Heatgrid(rows: (0..<5).map { r in (0..<12).map { c in MockData.seeded(r * 12 + c, 4) } }) }
            Card { VStack(spacing: 10) { HBar(label: "Claude Code", value: "10.9%", fraction: 0.8, color: AgentColor.claude); HBar(label: "Codex", value: "12.7%", fraction: 0.9, color: AgentColor.codex) } }
        }
        Card { PixelMeter(value: 0.62, height: 10) }
    }.padding(24).frame(width: 760).background(Brand.background)
}

#Preview("Tab strips") {
    struct Demo: View {
        @State var a: AIKeeperKit.Tab = .cost
        @State var b: AIKeeperKit.Tab = .briefing
        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                TabStrip(tabs: Area.insights.tabs, selection: $a)
                TabStrip(tabs: Area.cleanup.tabs, selection: $b)
            }.padding(.vertical, 24).frame(width: 760).background(Brand.background)
        }
    }
    return Demo()
}

#Preview("List rows") {
    Card(padding: 0) {
        RowList(items: [AttentionItem(id: "1", tone: .amber, title: "fix-billing-retry is waiting on you", subtitle: "Claude Code needs an approval", action: "Open") { _, _ in },
                        AttentionItem(id: "2", tone: .blue, title: "7 workspaces are safe to remove", subtitle: "27 GB", action: "Review") { _, _ in }]) { it in
            ListRow(title: it.title, subtitle: it.subtitle) { Dot(tone: it.tone) } trail: { Button(it.action) {}.controlSize(.small) }
        }
    }.padding(24).frame(width: 620).background(Brand.background).tint(Brand.accent)
}

#Preview("Filters and page header") {
    Page(title: "Reliability", subtitle: "What fails, what loops, and what costs you retries", action: "Set an alert", sample: true) {
        FilterPills(items: ["Last 30 days", "Compare to previous period", "All agents"])
    }.frame(width: 760, height: 200).background(Brand.background)
}
