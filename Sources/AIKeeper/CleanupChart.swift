import SwiftUI

/// A year of cleanups drawn like a contribution graph: one square per day, darker for more space freed.
struct CleanupChart: View {
    @EnvironmentObject var store: Store
    @State private var records: [CleanRecord] = CleanLog.all()
    @State private var hover: CleanLog.Day?
    private let weekCount = 26
    private let cell: CGFloat = 12, gap: CGFloat = 3

    private var finishedJobs: Int { store.jobs.filter { $0.state == .finished }.count }

    var body: some View {
        let s = CleanLog.summary(records)
        let weeks = CleanLog.weeks(count: weekCount)
        let peak = weeks.flatMap { $0 }.compactMap { $0.flatMap { s.days[$0]?.bytes } }.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Space you got back", trailing: s.runs == 0 ? nil : "\(s.activeDays) day\(s.activeDays == 1 ? "" : "s") with a cleanup")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.totalBytes.bytesString).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Text(s.first.map { "freed since \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? "freed so far").foregroundStyle(.secondary)
            }
            if s.runs == 0 {
                Text("Nothing cleaned yet. Each day you remove something gets a square here.").font(.bCallout).foregroundStyle(.secondary)
            }
            grid(weeks, s, peak)
            HStack(spacing: 18) {
                if s.runs > 0 {
                    stat("Current streak", "\(s.currentStreak) day\(s.currentStreak == 1 ? "" : "s")")
                    stat("Longest streak", "\(s.longestStreak) day\(s.longestStreak == 1 ? "" : "s")")
                    if let b = s.best { stat("Best day", b.bytes.bytesString) }
                }
                Spacer()
                Text(hoverText ?? "").font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                legend
            }.font(.bCaption)
        }
        .onAppear { records = CleanLog.all() }
        .onChange(of: finishedJobs) { _ in records = CleanLog.all() }
    }

    private var hoverText: String? {
        hover.map { "\($0.bytes.bytesString) on \($0.day.formatted(.dateTime.month(.abbreviated).day()))" }
    }

    private func grid(_ weeks: [[Date?]], _ s: CleanLog.Summary, _ peak: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: gap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { i, w in
                    Text(monthLabel(i, w, weeks)).font(.bCaption2).foregroundStyle(.secondary).fixedSize().frame(width: cell, alignment: .leading)
                }
            }
            HStack(spacing: gap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            if let day = w[d] {
                                let rec = s.days[day]
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(color(CleanLog.level(rec?.bytes ?? 0, peak: peak)))
                                    .frame(width: cell, height: cell)
                                    .onHover { inside in hover = inside ? (rec ?? CleanLog.Day(day: day, bytes: 0, runs: 0)) : nil }
                                    .accessibilityLabel("\(day.formatted(.dateTime.month().day())): \((rec?.bytes ?? 0).bytesString) freed")
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        }
    }

    private func monthLabel(_ i: Int, _ w: [Date?], _ weeks: [[Date?]]) -> String {
        guard let first = w.compactMap({ $0 }).first else { return "" }
        let cal = Calendar.current
        if i == 0 || cal.component(.month, from: first) != cal.component(.month, from: weeks[i - 1].compactMap { $0 }.first ?? first) {
            return first.formatted(.dateTime.month(.abbreviated))
        }
        return ""
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.14) : Brand.accent.opacity([0, 0.3, 0.5, 0.75, 1][level])
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) { Text(label).foregroundStyle(.secondary); Text(value).fontWeight(.medium) }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(color($0)).frame(width: 10, height: 10) }
            Text("More").foregroundStyle(.secondary)
        }
    }
}
