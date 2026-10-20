import Charts
import SwiftUI

struct DiskSample: Codable {
    let t: Date
    let free: Int64
    let used: Int64
}

struct SizeSnapshot: Codable {
    let t: Date
    let sizes: [String: Int64]
}

struct GuardAlert: Identifiable {
    enum Kind { case low, rapid, budget }
    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

/// Processes that write a lot to disk; named in alerts so you know what to stop.
enum BuildProcs {
    static func scan() -> [String] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,command="]).out
        let rx = try! NSRegularExpression(pattern: #"(^|/)(cargo|rustc|npm|pnpm|yarn|docker|buildkitd|xcodebuild|gradle|pip3?|uv)( |$)"#)
        var found: [(pid: String, name: String)] = []
        for line in out.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let sp = s.firstIndex(of: " ") else { continue }
            let cmd = String(s[s.index(after: sp)...])
            if let m = rx.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)), let r = Range(m.range(at: 2), in: cmd) {
                found.append((String(s[..<sp]), String(cmd[r])))
            }
            if found.count >= 6 { break }
        }
        guard !found.isEmpty else { return [] }
        let cw = Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", found.map(\.pid).joined(separator: ",")]).out
        var cwd: [String: String] = [:]
        var cur = ""
        for l in cw.split(separator: "\n") {
            if l.hasPrefix("p") { cur = String(l.dropFirst()) } else if l.hasPrefix("n") { cwd[cur] = String(l.dropFirst()) }
        }
        // "cargo and rustc in X" rather than "cargo in X, rustc in X".
        var order: [String] = [], names: [String: [String]] = [:]
        for f in found {
            let place = cwd[f.pid].map { ($0 as NSString).lastPathComponent } ?? ""
            if names[place] == nil { order.append(place) }
            if !(names[place] ?? []).contains(f.name) { names[place, default: []].append(f.name) }
        }
        return order.map { place in
            let who = (names[place] ?? []).joined(separator: " and ")
            return place.isEmpty ? who : "\(who) in \(place)"
        }
    }
}

extension Store {
    var floorBytes: Int64 { Int64(UserDefaults.standard.number("guard.floorGB", default: 50) * 1e9) }
    var rapidDropBytes: Int64 { Int64(UserDefaults.standard.number("guard.rateGB", default: 10) * 1e9) }

    /// Runs every ~30s: record free space, raise alerts.
    func guardTick() async {
        refreshDisk()
        let now = Date()
        // Fine-grained history stays private (fast-drop detection). The charted history is 5-minute resolution,
        // so it publishes rarely and never holds more than ~4,000 points.
        if recentSamples.last.map({ now.timeIntervalSince($0.t) >= 55 }) ?? true {
            recentSamples.append(DiskSample(t: now, free: disk.available, used: disk.used))
            recentSamples.removeAll { now.timeIntervalSince($0.t) > 30 * 60 }
        }
        if samples.last.map({ now.timeIntervalSince($0.t) >= 295 }) ?? true {
            samples.append(DiskSample(t: now, free: disk.available, used: disk.used))
            samples.removeAll { now.timeIntervalSince($0.t) > 14 * 86_400 }
            let snapshot = samples
            Task.detached(priority: .utility) { Persist.save(snapshot, "disk-samples.json") }
        }

        // Spend budgets: refresh usage every 5 minutes and compare with the limits from Settings.
        if now.timeIntervalSince(lastUsageLoad) > 300 { lastUsageLoad = now; loadUsage() }
        let cal = Calendar.current
        let dayCost = usage.filter { cal.isDateInToday($0.day) }.reduce(0) { $0 + $1.cost }
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        let weekCost = usage.filter { $0.day >= weekStart }.reduce(0) { $0 + $1.cost }
        let daily = UserDefaults.standard.number("budget.daily", default: 0), weekly = UserDefaults.standard.number("budget.weekly", default: 0)
        if daily > 0, dayCost >= daily, cooledDown("budget.daily", hours: 12) {
            raise(.budget, "Daily AI budget reached", String(format: "$%.2f spent today against a $%.0f budget.", dayCost, daily))
        }
        if weekly > 0, weekCost >= weekly, cooledDown("budget.weekly", hours: 24) {
            raise(.budget, "Weekly AI budget reached", String(format: "$%.2f spent in the last 7 days against a $%.0f budget.", weekCost, weekly))
        }

        if disk.total > 0, disk.available < floorBytes, cooledDown("low", hours: 6) {
            raise(.low, "Low disk space",
                  "Only \(disk.available.bytesString) free. Clean build folders to get \(keptArtifactBytes.bytesString) back.")
        }
        // Compare with ~10 minutes ago.
        if let then = recentSamples.last(where: { now.timeIntervalSince($0.t) >= 540 }),
           then.free - disk.available >= rapidDropBytes, cooledDown("rapid", hours: 0.5) {
            let drop = (then.free - disk.available).bytesString
            let who = await Task.detached { BuildProcs.scan() }.value
            raise(.rapid, "Disk filling fast",
                  "Free space fell \(drop) in about 10 minutes." + (who.isEmpty ? "" : " Likely cause: \(who.prefix(3).joined(separator: ", ")).") )
        }
    }

    private func cooledDown(_ key: String, hours: Double) -> Bool {
        if let last = lastAlert[key], Date().timeIntervalSince(last) < hours * 3600 { return false }
        lastAlert[key] = Date()
        return true
    }

    func raise(_ kind: GuardAlert.Kind, _ title: String, _ message: String) {
        alert = GuardAlert(kind: kind, title: title, message: message)
        Notifier.send(title, message, id: "aikeeper.\(title)")
    }

    // MARK: Growth

    func recordSnapshot() {
        var sizes: [String: Int64] = [:]
        for e in buildHolders { for a in e.artifacts { sizes[a.path] = a.bytes } }
        for h in map?.hotspots ?? [] { sizes[h.path] = h.size }
        snapshots.append(SizeSnapshot(t: .now, sizes: sizes))
        snapshots = Array(snapshots.suffix(60))
        Persist.save(snapshots, "sizes.json")
    }

    /// Bytes gained since the newest snapshot that is at least ~20h old (or the oldest one if younger than that).
    func growth(of path: String, current: Int64) -> Int64? {
        let cutoff = Date().addingTimeInterval(-20 * 3600)
        guard let base = snapshots.last(where: { $0.t <= cutoff }) ?? (snapshots.count > 1 ? snapshots.first : nil),
              Date().timeIntervalSince(base.t) > 1800, let old = base.sizes[path] else { return nil }
        let d = current - old
        return abs(d) >= 200_000_000 ? d : nil
    }

    /// Biggest growers among known build folders.
    var fastestGrowing: [(path: String, delta: Int64)] {
        var out: [(String, Int64)] = []
        for e in buildHolders { for a in e.artifacts { if let g = growth(of: a.path, current: a.bytes), g >= 1_000_000_000 { out.append((a.path, g)) } } }
        return out.sorted { $0.1 > $1.1 }.prefix(3).map { ($0.0, $0.1) }
    }
}

// MARK: - Views

struct AlertBanner: View {
    @EnvironmentObject var store: Store
    let alert: GuardAlert
    let go: (Section) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.kind == .budget ? "dollarsign.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).fontWeight(.semibold)
                Text(alert.message).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if alert.kind == .budget {
                Button("See usage") { go(.usage); store.alert = nil }
            } else {
                if store.keptArtifactBytes > 0 {
                    Button("Clean build folders") { store.propose(.purgeArtifacts, for: store.buildHolders); store.alert = nil }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
                Button("Agents") { go(.agents); store.alert = nil }
            }
            Button { store.alert = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss alert")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        // Opaque: a see-through banner let the content underneath print through the text.
        .background(Color(nsColor: .windowBackgroundColor).overlay(Color.orange.opacity(0.12)))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct FreeSpaceChart: View {
    @EnvironmentObject var store: Store
    @State private var hours = 24

    /// Keep every Nth point so a week of history never means thousands of chart marks.
    static func downsample(_ pts: [DiskSample], to limit: Int) -> [DiskSample] {
        guard pts.count > limit else { return pts }
        let step = Double(pts.count) / Double(limit)
        return (0..<limit).map { pts[min(pts.count - 1, Int(Double($0) * step))] } + [pts[pts.count - 1]]
    }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let pts = Self.downsample(store.samples.filter { $0.t >= cutoff }, to: 240)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Free space over time").font(.headline)
                Spacer()
                Picker("", selection: $hours) { Text("24 hours").tag(24); Text("7 days").tag(168) }
                    .pickerStyle(.segmented).frame(width: 170).labelsHidden()
            }
            if pts.count < 3 {
                Text("History builds up while the app runs. Keep it in the menu bar and this fills in.")
                    .foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(pts, id: \.t) { s in
                        AreaMark(x: .value("Time", s.t), y: .value("Free GB", Double(s.free) / 1e9)).foregroundStyle(.green.opacity(0.18))
                        LineMark(x: .value("Time", s.t), y: .value("Free GB", Double(s.free) / 1e9)).foregroundStyle(.green)
                    }
                    RuleMark(y: .value("Floor", Double(store.floorBytes) / 1e9))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.orange)
                        .annotation(position: .top, alignment: .leading) { Text("alert floor").font(.caption2).foregroundStyle(.orange) }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GB") } } } }
                .frame(height: 140)
            }
            let growers = store.fastestGrowing
            if !growers.isEmpty {
                Divider()
                ForEach(growers, id: \.path) { g in
                    HStack {
                        Image(systemName: "arrow.up.right").foregroundStyle(.orange)
                        Text(g.path.replacingOccurrences(of: home, with: "~")).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text("+\(g.delta.bytesString) since yesterday").foregroundStyle(.orange).monospacedDigit()
                    }.font(.callout)
                }
            }
        }
        .padding(16).panel()
    }
}
