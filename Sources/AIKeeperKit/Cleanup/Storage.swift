import SwiftUI

// Cleanup › Overview: how full the Mac is and what fills it, then the quickest ways to get space back.

enum StorageCategory: String, CaseIterable, Identifiable {
    case apps = "Apps", developer = "Developer", agent = "Agent data", media = "Media", documents = "Documents", system = "System and other"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .apps: Color(red: 0.30, green: 0.55, blue: 0.96); case .developer: Color(red: 0.08, green: 0.72, blue: 0.65)
        case .agent: Color(red: 0.48, green: 0.51, blue: 1.0); case .media: Color(red: 0.93, green: 0.28, blue: 0.60)
        case .documents: Color(red: 0.22, green: 0.74, blue: 0.97); case .system: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }
    /// Folders measured for this category. System and other is whatever is left of the used space.
    var folders: [String] {
        switch self {
        case .apps: ["/Applications", home + "/Applications"]
        case .developer: [home + "/Developer", home + "/Library/Developer", home + "/.cargo", home + "/.rustup", home + "/.npm", home + "/.gradle", home + "/.docker", home + "/.cache"]
        case .agent: [home + "/.claude", home + "/.codex", home + "/.cursor", home + "/.gemini", home + "/.conductor", home + "/.superset", home + "/.pi"]
        case .media: [home + "/Movies", home + "/Music", home + "/Pictures"]
        case .documents: [home + "/Documents", home + "/Desktop", home + "/Downloads"]
        case .system: []
        }
    }
    var tab: Destination? {
        switch self { case .apps: .area(.cleanup, .apps); case .developer: .area(.cleanup, .clean); case .agent: .agentData; case .media, .documents: .area(.cleanup, .files); case .system: nil }
    }
}

@MainActor @Observable final class StorageModel {
    var bytes: [StorageCategory: Int64] = [:]
    var measuredAt: Date?
    var measuring = false

    func measureIfNeeded() async { if measuredAt == nil { await measure() } }

    func measure() async {
        if Demo.enabled { bytes = [.apps: 74e9, .developer: 96e9, .agent: 71e9, .media: 38e9, .documents: 42e9].mapValues { Int64($0) }; measuredAt = Date(); return }
        measuring = true
        let result = await withTaskGroup(of: (StorageCategory, Int64).self) { g -> [StorageCategory: Int64] in
            for c in StorageCategory.allCases where c != .system {
                g.addTask(priority: .utility) { (c, c.folders.filter { FileManager.default.fileExists(atPath: $0) }.reduce(Int64(0)) { $0 + Shell.du($1) }) }
            }
            var out: [StorageCategory: Int64] = [:]
            for await (c, b) in g { out[c] = b }
            return out
        }
        bytes = result; measuredAt = Date(); measuring = false
    }

    /// The segments of the bar, in order, with the remainder as system and other.
    func segments(_ disk: DiskInfo) -> [(StorageCategory, Int64)] {
        let known = StorageCategory.allCases.filter { $0 != .system }.map { ($0, bytes[$0] ?? 0) }
        let rest = max(0, disk.used - disk.purgeable - known.reduce(0) { $0 + $1.1 })
        return known + [(.system, rest)]
    }
}

/// The stacked bar used by the overview, the sidebar card and the popover. Free space is the empty end.
struct StorageBar: View {
    let disk: DiskInfo
    let segments: [(StorageCategory, Int64)]
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { g in
            let total = CGFloat(max(disk.total, 1))
            HStack(spacing: 1) {
                ForEach(segments, id: \.0) { c, b in Rectangle().fill(c.color).frame(width: max(0, g.size.width * CGFloat(b) / total - 1)) }
                if disk.purgeable > 0 { Rectangle().fill(Brand.mutedForeground.opacity(0.3)).frame(width: g.size.width * CGFloat(disk.purgeable) / total) }
                Rectangle().fill(Brand.muted)
            }.clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }.frame(height: height).accessibilityHidden(true)
    }
}

struct StorageOverview: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket

    var body: some View {
        let disk = store.disk
        ScrollView {
            VStack(spacing: 18) {
                hero(disk)
                HStack(alignment: .top, spacing: 18) { categories(disk).frame(maxWidth: .infinity); wins.frame(width: 400) }
            }.padding(.horizontal, 28).padding(.vertical, 14).frame(maxWidth: 1240)
        }
        .task { await store.storage.measureIfNeeded() }
    }

    private func hero(_ disk: DiskInfo) -> some View {
        let free = disk.available.byteParts
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { Text(free.number).font(.system(size: 44, weight: .bold)).monospacedDigit(); Text(free.unit + " free").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary) }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) { Text("Macintosh HD").font(.bBody.weight(.semibold)); Text("\(disk.used.bytesString) used of \(disk.total.bytesString)").font(.bCaption).foregroundStyle(.secondary) }
            }
            StorageBar(disk: disk, segments: store.storage.segments(disk), height: 16)
            HStack(spacing: 16) {
                ForEach(store.storage.segments(disk), id: \.0) { c, b in
                    HStack(spacing: 6) { Circle().fill(c.color).frame(width: 8, height: 8); Text(c.rawValue).font(.bCaption); Text(store.storage.measuredAt == nil ? "…" : b.bytesString).font(.bCaption).foregroundStyle(.secondary).monospacedDigit() }
                }
                if disk.purgeable > 0 { HStack(spacing: 6) { Circle().fill(Brand.mutedForeground.opacity(0.3)).frame(width: 8, height: 8); Text("Purgeable").font(.bCaption); Text(disk.purgeable.bytesString).font(.bCaption).foregroundStyle(.secondary).monospacedDigit() } }
                Spacer()
            }.lineLimit(1)
            if disk.purgeable > 0 { Text("Purgeable space is what macOS gives back by itself when it needs room, such as iCloud copies and old caches. It counts as free.").font(.bCaption2).foregroundStyle(.secondary) }
        }
        .padding(22).background(Brand.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.edge))
    }

    private func categories(_ disk: DiskInfo) -> some View {
        let segs = store.storage.segments(disk)
        let top = max(segs.map(\.1).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack { Text("What takes the room").font(.bHeadline); Spacer(); if store.storage.measuring { ProgressView().controlSize(.small) } else { Button("Remeasure") { Task { await store.storage.measure() } }.buttonStyle(.plain).foregroundStyle(Brand.primaryText).font(.bCaption) } }.padding(.horizontal, 18).padding(.vertical, 14)
            ForEach(segs.sorted { $0.1 > $1.1 }, id: \.0) { c, b in
                Button { if let d = c.tab { nav.go(d) } } label: {
                    VStack(spacing: 6) {
                        HStack { Circle().fill(c.color).frame(width: 9, height: 9); Text(c.rawValue).font(.bBody.weight(.medium)); Spacer(); Text(store.storage.measuredAt == nil ? "…" : b.bytesString).font(.bBody).monospacedDigit(); if c.tab != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) } }
                        GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(c.color).frame(width: g.size.width * CGFloat(b) / CGFloat(top)) } }.frame(height: 4)
                    }.padding(.horizontal, 18).padding(.vertical, 11).contentShape(Rectangle())
                }.buttonStyle(.plain).overlay(alignment: .top) { Divider() }
            }
            Text("Measured from your home folder and /Applications. System and other is everything else macOS reports as used.").font(.bCaption2).foregroundStyle(.secondary).padding(18).overlay(alignment: .top) { Divider() }
        }.background(Brand.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.edge))
    }

    private var wins: some View {
        let safe = store.stats.safeBytes
        let big = store.files.files.filter { $0.bytes >= 500_000_000 }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Quickest ways to get space back").font(.bHeadline).padding(.horizontal, 18).padding(.vertical, 14)
            win("trash", .green, "Developer and cache clutter", "Safe to clear, nothing lost", safe, safe == 0 ? nil : "Reclaim") { basket.resetToSafe(); nav.showBasket = true }
            win("square.grid.2x2", .blue, "Apps you have not opened in 90 days", "\(store.apps.unused.count) apps", store.apps.unusedBytes, store.apps.loaded ? "Review" : nil) { nav.go(.area(.cleanup, .apps)) }
            win("tray.full", .gray, "Leftovers of apps you removed", "\(store.apps.orphans.count) apps", store.apps.orphanBytes, store.apps.orphanBytes > 0 ? "Review" : nil) { nav.go(.area(.cleanup, .apps)) }
            win("doc.on.doc", .amber, "Big files over 500 MB", "\(big.count) files", big.reduce(0) { $0 + $1.bytes }, store.files.loaded ? "Review" : nil) { nav.go(.area(.cleanup, .files)) }
            if !store.apps.loaded || !store.files.loaded {
                Button("Look for apps and big files") { Task { await store.apps.measureIfNeeded(); await store.files.scanIfNeeded() } }.buttonStyle(.brandOutline).padding(18)
            }
        }.background(Brand.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.edge))
    }

    private func win(_ symbol: String, _ tone: Tone, _ title: String, _ sub: String, _ bytes: Int64, _ action: String?, run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            TierChip(symbol: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.bBody.weight(.medium)); Text(sub).font(.bCaption).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            Text(bytes > 0 ? bytes.bytesString : "–").font(.bBody.weight(.semibold)).monospacedDigit()
            if let action { Button(action, action: run).controlSize(.small) }
        }.padding(.horizontal, 18).padding(.vertical, 11).overlay(alignment: .top) { Divider() }
    }
}
