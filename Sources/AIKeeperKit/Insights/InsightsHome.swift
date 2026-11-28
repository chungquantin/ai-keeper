import SwiftUI

// Insights: a short list of things worth changing, each with the evidence behind it, and a list to look deeper.

/// Findings the user dismissed. A finding comes back when its wording changes, because the numbers in it did.
enum InsightDismissals {
    private static let file = "insights-dismissed.json"
    static func all() -> [String: String] { Persist.load([String: String].self, file) ?? [:] }
    static func dismiss(_ t: Tip) { var d = all(); d[t.id] = t.body; Persist.save(d, file) }
    static func isDismissed(_ t: Tip, in d: [String: String]) -> Bool { d[t.id] == t.body }
}

struct InsightsHome: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var dismissed = InsightDismissals.all()

    private static let maxFindings = 4

    var body: some View {
        let tips = Array(store.advice.tips.filter { !InsightDismissals.isDismissed($0, in: dismissed) }.prefix(Self.maxFindings))
        Page {
            AdaptiveRow(spacing: 20, minChild: 460) {
                VStack(spacing: 14) {
                    if tips.isEmpty { empty } else { ForEach(tips) { FindingCard(tip: $0) { InsightDismissals.dismiss($0); dismissed = InsightDismissals.all() } } }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 14) { deeper }.frame(width: 340)
            }
        }
    }

    private var empty: some View {
        Card(padding: 28) {
            VStack(spacing: 10) {
                SleepingRobot()
                Text(store.traces.isEmpty ? "Reading your sessions…" : "Nothing to change right now").font(.bHeadline)
                Text("We look at your last 30 days again as your sessions change.").font(.bCaption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
    }

    private var deeper: some View {
        let agg = store.advice.agg
        let turn = TraceAgg.median(agg.turnSeconds)
        let rows: [(String, String, String, Tab)] = [
            ("Cost", "By model, agent and day", String(format: "$%.0f this week", store.spentWeek), .cost),
            ("Speed", "Where agent time goes", turn > 0 ? (turn >= 90 ? String(format: "%.1f min a turn", turn / 60) : String(format: "%.0f s a turn", turn)) : "", .speed),
            ("Reliability", "What fails and loops", agg.toolCalls > 0 ? "\(Int((agg.failRate * 100).rounded()))% failed" : "", .reliability),
            ("Context", "Tokens and cache", agg.bigContext > 0 ? "\(agg.bigContext) long" : "", .context),
            ("Advisor", "Which agent for which task", store.advice.tips.isEmpty ? "" : "\(store.advice.tips.count)", .advisor),
            ("Machine", "What agents cost this Mac", "", .machine),
        ]
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Look deeper").padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
                ForEach(rows.indices, id: \.self) { i in
                    Button { nav.tab[.insights] = rows[i].3 } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) { Text(rows[i].0).font(.bBody.weight(.semibold)); Text(rows[i].1).font(.bCaption).foregroundStyle(.secondary) }
                            Spacer(minLength: 6)
                            Text(rows[i].2).font(.bCaption.weight(.medium)).monospacedDigit()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }.padding(.horizontal, 18).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(HoverRowStyle()).overlay(alignment: .top) { Divider() }
                }
            }
        }
    }
}

private struct FindingCard: View {
    let tip: Tip
    let dismiss: (Tip) -> Void
    @Environment(NavState.self) private var nav

    private var tone: Tone { switch tip.group { case .agent: .violet; case .harness: .amber; case .habit: .blue } }
    private var symbol: String { switch tip.group { case .agent: "arrow.left.arrow.right"; case .harness: "bolt"; case .habit: "clock.arrow.circlepath" } }

    var body: some View {
        Card(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                TierChip(symbol: symbol, tone: tone, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tip.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(tip.body).font(.bCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).help(tip.why)
                if !tip.value.isEmpty {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(tip.value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1)
                        GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(tone.fg).frame(width: max(4, g.size.width * min(max(tip.fraction, 0), 1))) } }.frame(width: 96, height: 5)
                        Text(tip.caption).font(.bCaption2).foregroundStyle(.secondary).lineLimit(1)
                    }.fixedSize()
                }
                HStack(spacing: 6) {
                    Button(tip.action) { nav.open(tip.area, tip.tab) }.buttonStyle(.brandProminent).controlSize(.small).fixedSize()
                    Button { dismiss(tip) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.controlSize(.small).help("Dismiss").accessibilityLabel("Dismiss")
                }
            }
        }
    }
}
