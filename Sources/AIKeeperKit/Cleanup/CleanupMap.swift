import SwiftUI

// Cleanup › Map: the whole pile as tiles. Area is size on disk, color is what losing it would cost.

private struct MapTile: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let bytes: Int64
    let tier: Tier?              // nil: in use, or not ours to remove
    var item: ReclaimItem?
    var source: DataSource?
    var docker = false
}

struct CleanupMap: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Seg([("Trust map", MapMode.trust), ("Folders", MapMode.folders), ("Duplicates", MapMode.duplicates)], selection: Bindable(nav).mapMode)
                Spacer()
            }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 6)
            switch nav.mapMode {
            case .trust: TrustMap()
            case .folders: DiskView(model: store.analyzer)
            case .duplicates: DedupView(model: store.dedup)
            }
        }
    }
}

private struct TrustMap: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket
    @State private var selected: String?

    private func tiles() -> [MapTile] {
        var out: [MapTile] = []
        let items = store.reclaimItems
        for i in items {
            out.append(MapTile(id: "item:" + i.id, title: i.kind == .buildFolders ? "Build folders" : i.kind == .caches ? "Tool caches" : i.kind == .merged ? "\(i.count) merged workspaces"
                               : i.kind == .leftovers ? "Leftover chat history" : "\(i.count) with unsaved work",
                               subtitle: i.tier.meaning.prefix(1).uppercased() + i.tier.meaning.dropFirst(), bytes: i.bytes, tier: i.tier, item: i))
        }
        let active = store.stats.buildHolders.filter { $0.verdict == .active }
        let inUse = active.reduce(Int64(0)) { $0 + max(($1.size ?? 0) - $1.artifactBytes, 0) }
        if inUse > 0 { out.append(MapTile(id: "inuse", title: "In use", subtitle: "\(active.count) active workspaces and main checkouts", bytes: inUse, tier: nil)) }
        for s in store.sources.sources() { if let b = store.sources.bytes(s), b > 0 { out.append(MapTile(id: "src:" + s.id, title: s.name, subtitle: s.detail, bytes: b, tier: s.tier, source: s)) } }
        if let d = store.sources.dockerTotal, d > 0 { out.append(MapTile(id: "docker", title: "Docker and OrbStack", subtitle: "Images and build cache", bytes: d, tier: .rebuildable, docker: true)) }
        // Slivers are noise on a map: fold anything under 1.5% into one tile.
        let total = max(out.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        let big = out.filter { Double($0.bytes) / Double(total) >= 0.015 }
        let small = out.filter { Double($0.bytes) / Double(total) < 0.015 }
        return small.isEmpty ? big : big + [MapTile(id: "other", title: "\(small.count) smaller", subtitle: "Each under 2%", bytes: small.reduce(0) { $0 + $1.bytes }, tier: nil)]
    }

    var body: some View {
        let tiles = self.tiles()
        let cur = tiles.first { $0.id == selected } ?? tiles.max { $0.bytes < $1.bytes }
        GeometryReader { g in
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    mapCard(tiles, cur)
                    HStack(spacing: 18) {
                        Legend(items: Tier.allCases.map { ($0.title, $0.color) } + [("In use or not ours", Color.secondary.opacity(0.5))])
                        Spacer()
                        Text("Tile area is size on disk. Click a tile to open it.").font(.bCaption).foregroundStyle(.secondary)
                    }
                }
                if g.size.width > 900 { side(cur).frame(width: 330) }
            }
            .padding(.horizontal, 28).padding(.bottom, 20).padding(.top, 4)
        }
        .task { await store.sources.measureIfNeeded() }
    }

    private func mapCard(_ tiles: [MapTile], _ cur: MapTile?) -> some View {
        GeometryReader { g in
            let rect = CGRect(x: 0, y: 0, width: g.size.width, height: g.size.height).insetBy(dx: 6, dy: 6)
            let placed = Self.layout(tiles, rect)
            ZStack(alignment: .topLeading) {
                ForEach(placed, id: \.0.id) { t, r in tileView(t, r.insetBy(dx: 2, dy: 2), on: t.id == cur?.id) }
                if tiles.isEmpty {
                    Text(store.isScanning || !store.hasData ? "Measuring…" : "Nothing to map yet.").font(.bCallout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .panel()
    }

    private func tileView(_ t: MapTile, _ r: CGRect, on: Bool) -> some View {
        let tone: Tone? = t.tier?.tone
        return Button { selected = t.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                if r.width > 80 && r.height > 44 {
                    Text(t.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    if r.height > 84 && r.width > 130 { Text(t.subtitle).font(.system(size: 11)).opacity(0.85).lineLimit(2) }
                    Spacer(minLength: 0)
                    Text(t.bytes.bytesString).font(.system(size: r.width > 150 ? 18 : 14, weight: .semibold)).monospacedDigit()
                }
            }
            .foregroundStyle(tone?.fg ?? Brand.mutedForeground)
            .padding(10).frame(width: r.width, height: r.height, alignment: .topLeading)
            .background((tone?.bg ?? Brand.muted), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Brand.accent : (tone?.fg.opacity(0.25) ?? Brand.border), lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("\(t.title): \(t.bytes.bytesString)")
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    // MARK: Side

    private func side(_ cur: MapTile?) -> some View {
        VStack(spacing: 14) {
            if let a = store.alert {
                Note(text: "\(a.title). \(a.message)")
            }
            Card(padding: 18) {
                if let t = cur {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text(t.title).font(.bHeadline).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if let tier = t.tier { Tag(text: tier.title, tone: tier.tone) } else { Tag(text: "Not ours") }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(t.bytes.byteParts.number).font(.figure(34)).monospacedDigit()
                            Text(t.bytes.byteParts.unit).font(.figure(15)).foregroundStyle(.secondary)
                        }
                        Text(t.item?.regret ?? t.subtitle).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        actions(t)
                    }
                } else { Text("Nothing selected.").font(.bCaption).foregroundStyle(.secondary) }
            }
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(title: "This Mac", note: store.disk.total > 0 ? "\(store.disk.available.bytesString) free" : nil)
                    if store.disk.total > 0 {
                        Ladder(parts: [(Double(store.stats.managedBytes), Brand.accent), (Double(max(store.disk.used - store.stats.managedBytes, 0)), Color.secondary.opacity(0.35)), (Double(store.disk.available), Brand.muted)], height: 10)
                        Legend(items: [("Agent workspaces \(store.stats.managedBytes.bytesString)", Brand.accent), ("Everything else", Color.secondary.opacity(0.5)), ("Free", Brand.muted)])
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func actions(_ t: MapTile) -> some View {
        if let item = t.item {
            let inBasket = basket.contains(item)
            Button { if !inBasket { basket.toggle(item) }; nav.open(.cleanup, .review) } label: { Text(inBasket ? "In your basket · open it" : "Add \(item.bytes.bytesString) to basket").frame(maxWidth: .infinity) }
                .buttonStyle(.brandProminent).controlSize(.large)
            Button { nav.open(.cleanup, .review) } label: { Text("See what is inside").frame(maxWidth: .infinity) }.controlSize(.large)
        } else if let s = t.source {
            Button { nav.open(.cleanup, .agentData) } label: { Text(s.archivable ? "Archive old sessions" : "Clear \(s.name)").frame(maxWidth: .infinity) }.buttonStyle(.brandProminent).controlSize(.large)
        } else if t.docker {
            Button { nav.dataMode = .containers; nav.open(.cleanup, .agentData) } label: { Text("Open containers").frame(maxWidth: .infinity) }.buttonStyle(.brandProminent).controlSize(.large)
        } else {
            Note(text: "This is in use, or it is not something an agent or dev tool made, so Keeper leaves it alone.")
        }
    }

    // MARK: Layout

    /// Binary split: sorted tiles are divided into two groups of about equal size, cut along the longer side, and each half is laid out again.
    fileprivate static func layout(_ tiles: [MapTile], _ r: CGRect) -> [(MapTile, CGRect)] {
        split(Array(tiles.sorted { $0.bytes > $1.bytes }), r)
    }

    private static func split(_ t: [MapTile], _ r: CGRect) -> [(MapTile, CGRect)] {
        if t.isEmpty { return [] }
        if t.count == 1 { return [(t[0], r)] }
        let total = max(t.reduce(0.0) { $0 + Double($1.bytes) }, 1)
        var acc = 0.0, cut = 1
        for i in 0..<t.count - 1 { acc += Double(t[i].bytes); cut = i + 1; if acc >= total / 2 { break } }
        let a = Array(t[0..<cut]), b = Array(t[cut...])
        let f = acc / total
        if r.width >= r.height {
            let w = r.width * f
            return split(a, CGRect(x: r.minX, y: r.minY, width: w, height: r.height)) + split(b, CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
        } else {
            let h = r.height * f
            return split(a, CGRect(x: r.minX, y: r.minY, width: r.width, height: h)) + split(b, CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
        }
    }
}
