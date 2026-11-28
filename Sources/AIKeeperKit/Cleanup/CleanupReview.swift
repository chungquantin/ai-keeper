import SwiftUI

// Cleanup › Review: everything you can clear, in three tiers by what losing it would cost,
// with a basket that shows the total before anything is touched.

// MARK: Small pieces

struct Check: View {
    let on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? Brand.accent : Brand.card)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(on ? Color.clear : Color.secondary.opacity(0.55), lineWidth: 1.5))
                .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white).opacity(on ? 1 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }
}

/// The three-part bar of the trust ladder: end caps rounded, the joins squared with a small gap.
struct Ladder: View {
    let parts: [(Double, Color)]
    var height: CGFloat = 14
    /// Spoken by VoiceOver in place of the bar, e.g. "Rebuildable 9 GB, On a remote 18 GB".
    var label: String = ""
    var body: some View {
        GeometryReader { g in
            let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
            let live = parts.filter { $0.0 > 0 }
            let room = g.size.width - CGFloat(max(live.count - 1, 0)) * 3
            HStack(spacing: 3) {
                ForEach(live.indices, id: \.self) { i in
                    UnevenRoundedRectangle(topLeadingRadius: i == 0 ? height / 2 : 4, bottomLeadingRadius: i == 0 ? height / 2 : 4,
                                           bottomTrailingRadius: i == live.count - 1 ? height / 2 : 4, topTrailingRadius: i == live.count - 1 ? height / 2 : 4, style: .continuous)
                        .fill(live[i].1).frame(width: max(4, room * live[i].0 / total))
                }
            }
        }
        .frame(height: height)
        .background(Capsule().fill(Brand.muted))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHidden(label.isEmpty)
    }
}

struct TierChip: View {
    let symbol: String
    let tone: Tone
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(tone.fg)
            .frame(width: size, height: size).background(tone.bg, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension Basket {
    /// Tick or untick one entry inside an item. Ticking inside an unticked item turns the item on with only that entry.
    func tick(_ e: Entry, in item: ReclaimItem) {
        if !contains(item) {
            toggle(item)
            for o in item.entries where o.id != e.id { excluded.insert(o.id) }
            excluded.remove(e.id)
        } else { toggleEntry(e) }
    }
    func isOn(_ e: Entry, in item: ReclaimItem) -> Bool { contains(item) && !excluded.contains(e.id) }
}

// MARK: Review

struct CleanupReview: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket
    @State private var detail: ReclaimItem.Kind?

    var body: some View {
        let items = store.reclaimItems
        GeometryReader { g in
            let wide = g.size.width >= 1000
            if let k = detail, let item = items.first(where: { $0.kind == k }) {
                ReclaimDetail(item: item) { detail = nil }
            } else {
                HStack(spacing: 0) {
                    tiers(items)
                    if wide { Divider(); BasketPanel(items: items) { detail = $0 }.frame(width: 320) }
                }
                .overlay(alignment: .bottom) { if !wide { BasketBar(items: items) } }
            }
        }
    }

    private func tiers(_ items: [ReclaimItem]) -> some View {
        Page {
            hero(items)
            if items.isEmpty {
                Card(padding: 28) {
                    VStack(spacing: 10) {
                        if store.isScanning || !store.hasData { RobotSpinner().scaleEffect(2).frame(height: 44) } else { SleepingRobot() }
                        Text(store.isScanning || !store.hasData ? "Measuring your workspaces…" : "Nothing to clear").font(.bHeadline)
                        Text(store.isScanning || !store.hasData ? "Results appear as they are measured." : "Every workspace is in use, and there are no build folders or caches to empty.")
                            .font(.bCaption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        columnHeader
                        ForEach(Tier.allCases) { tier in
                            let rows = items.filter { $0.tier == tier }
                            if !rows.isEmpty {
                                groupHeader(tier, rows)
                                ForEach(rows) { item in row(item) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func hero(_ items: [ReclaimItem]) -> some View {
        func total(_ t: Tier) -> Int64 { items.filter { $0.tier == t }.reduce(0) { $0 + $1.bytes } }
        let safe = items.filter { $0.tier.isSafe }.reduce(Int64(0)) { $0 + $1.bytes }
        let only = total(.onlyHere)
        let parts = safe.byteParts
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.hasData ? parts.number : "—").font(.figure(52)).monospacedDigit()
                    Text(parts.unit).font(.figure(20)).foregroundStyle(.secondary)
                    Text(safe == 0 ? "is safe to clear right now." : only > 0 ? "can go without losing any work. Another \(only.bytesString) needs a look first." : "can go without losing any work.")
                        .font(.bBody).padding(.leading, 6).fixedSize(horizontal: false, vertical: true)
                }
                Ladder(parts: Tier.allCases.map { (Double(total($0)), $0.color) }, label: Tier.allCases.map { "\($0.title) \(total($0).bytesString)" }.joined(separator: ", "))
                Legend(items: Tier.allCases.filter { total($0) > 0 }.map { ("\($0.title) \(total($0).bytesString) · \($0.meaning)", $0.color) })
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 16 + 30 + 12)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("If you regret it").frame(width: 190, alignment: .leading)
            Text("Size").frame(width: 70, alignment: .trailing)
            Text("Last used").frame(width: 76, alignment: .trailing)
            Color.clear.frame(width: 12)
        }
        .font(.bCaption2).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func groupHeader(_ tier: Tier, _ rows: [ReclaimItem]) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tier.color).frame(width: 7, height: 7)
            Text("\(tier.title) · \(rows.reduce(0) { $0 + $1.bytes }.bytesString)").font(.bCaption.weight(.semibold))
            if !tier.isSafe { Text("not selected").font(.bCaption).foregroundStyle(.secondary) }
            Spacer()
        }
        .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity).background(Brand.muted)
    }

    private func row(_ item: ReclaimItem) -> some View {
        Button { detail = item.kind } label: {
            HStack(spacing: 12) {
                Check(on: basket.contains(item)) { basket.toggle(item) }
                TierChip(symbol: item.symbol, tone: item.tier.tone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.bBody.weight(.semibold)).lineLimit(1)
                    Text(item.subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(item.regret).font(.bCaption).foregroundStyle(.secondary).lineLimit(2).frame(width: 190, alignment: .leading)
                Text(item.bytes.bytesString).font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
                Text(item.lastUsed.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) } ?? "").font(.bCaption2).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 12)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: Basket panel

struct BasketPanel: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket
    let items: [ReclaimItem]
    let open: (ReclaimItem.Kind) -> Void

    var body: some View {
        let picked = items.filter { basket.contains($0) && basket.bytes($0) > 0 }
        let total = basket.total(items)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Basket").font(.bHeadline)
                Spacer()
                Text("\(picked.count) item\(picked.count == 1 ? "" : "s") · \(total.bytesString)").font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Nothing is removed until you confirm. We ticked everything that is safe.").font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(picked) { item in
                    Button { open(item.kind) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(item.tier.color).frame(width: 7, height: 7)
                            Text(item.title).font(.bBody).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(basket.bytes(item).bytesString).font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).overlay(alignment: .top) { Divider() }
                }
                if picked.isEmpty { Text("Tick a row to add it.").font(.bCaption).foregroundStyle(.secondary).padding(.vertical, 8) }
            }
            VStack(alignment: .leading, spacing: 7) {
                promise("Rebuildable and On a remote items can be recreated.")
                promise("Skips any folder an agent is using.")
                promise("Only here items are saved as a snapshot first.")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 0)
            Button { nav.showBasket = true } label: { Text(total > 0 ? "Reclaim \(total.bytesString)" : "Nothing selected").frame(maxWidth: .infinity) }
                .buttonStyle(.brandProminent).controlSize(.large).disabled(total == 0)
            if basket.total(items) != store.stats.safeBytes || items.contains(where: { !$0.tier.isSafe && basket.contains($0) }) {
                Button("Back to the safe selection") { basket.resetToSafe() }.buttonStyle(.plain).font(.bCaption).foregroundStyle(Brand.primaryText).frame(maxWidth: .infinity)
            }
        }
        .padding(20).frame(maxHeight: .infinity, alignment: .top).background(Brand.card)
    }

    private func promise(_ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentColor.good)
            Text(t).font(.bCaption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// On a narrow window the basket collapses to one bar along the bottom.
struct BasketBar: View {
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket
    let items: [ReclaimItem]
    var body: some View {
        let total = basket.total(items)
        HStack {
            Text("\(basket.count(items)) selected · \(total.bytesString)").font(.bCallout).monospacedDigit()
            Spacer()
            Button("Reclaim \(total.bytesString)") { nav.showBasket = true }.buttonStyle(.brandProminent).disabled(total == 0)
        }
        .padding(.horizontal, 20).frame(height: 56).background(.bar).overlay(alignment: .top) { Divider() }
    }
}

// MARK: Detail

/// One group opened up: every workspace in it, with the facts behind its verdict.
struct ReclaimDetail: View {
    @Environment(Store.self) private var store
    @Environment(Basket.self) private var basket
    let item: ReclaimItem
    let back: () -> Void
    @State private var selected: String?
    @State private var query = ""

    private var rows: [Entry] {
        var l = item.entries.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        if !query.isEmpty { l = l.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.branch ?? "").localizedCaseInsensitiveContains(query) || $0.repoName.localizedCaseInsensitiveContains(query) } }
        return l
    }

    var body: some View {
        let rows = self.rows
        let sel = rows.first { $0.id == selected } ?? rows.first
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { back() } label: { Label("Review", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Brand.primaryText)
                    Text("›").foregroundStyle(.tertiary)
                    Tag(text: item.tier.title, tone: item.tier.tone)
                    Text(item.title).font(.bBody.weight(.semibold)).lineLimit(1)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search name or branch", text: $query).textFieldStyle(.plain).frame(width: 170)
                    }.padding(.horizontal, 10).frame(height: 28).background(Brand.muted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.padding(.horizontal, 28).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { e in entryRow(e, on: e.id == sel?.id) }
                    }
                }
                .background(Brand.card).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
                .padding(.horizontal, 28)
                HStack(spacing: 12) {
                    let n = item.entries.filter { basket.isOn($0, in: item) }.count
                    Text("\(n) of \(item.count) selected · \(basket.bytes(item).bytesString)").font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Select all") { basket.excluded.subtract(item.entries.map(\.id)); if !basket.contains(item) { basket.toggle(item) } }
                    Button("Select none") { if basket.contains(item) { basket.toggle(item) } }
                    Button("Done") { back() }.buttonStyle(.brandProminent)
                }.padding(.horizontal, 28).frame(height: 56)
            }
            Divider()
            if let sel { inspector(sel).frame(width: 340) }
        }
    }

    private func entryRow(_ e: Entry, on: Bool) -> some View {
        Button { selected = e.id } label: {
            HStack(spacing: 12) {
                Check(on: basket.isOn(e, in: item)) { basket.tick(e, in: item) }
                Image(systemName: e.sources.sorted { $0.rawValue < $1.rawValue }.first?.symbol ?? "folder").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).font(.bBody.weight(.medium)).lineLimit(1)
                    Text(e.branch.map { "\(e.repoName) · \($0)" } ?? e.repoName).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Tag(text: Self.evidenceText(e), tone: item.tier.tone).frame(width: 140, alignment: .leading)
                Text(Basket.cost(e, item: item, buildOnly: basket.buildOnly).bytesString).font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
                Text(e.lastActivity.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) } ?? "").font(.bCaption2).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 9).background(on ? Brand.primaryTint : Color.clear).contentShape(Rectangle())
        }
        .buttonStyle(.plain).overlay(alignment: .top) { Divider() }
    }

    static func evidenceText(_ e: Entry) -> String {
        if let pr = e.pr { return "PR #\(pr.number) " + (pr.state == "MERGED" ? "merged" : pr.state == "CLOSED" ? "closed" : "open") }
        if let g = e.git {
            if g.merged { return "Branch merged" }
            if g.dirtyCount > 0 { return "\(g.dirtyCount) uncommitted" }
            if g.unpushed > 0 { return "\(g.unpushed) unpushed" }
        }
        switch e.kind { case .cache: return "Cache"; case .sessionData: return "Project gone"; default: return "No activity" }
    }

    private func inspector(_ e: Entry) -> some View {
        let proof = ReclaimPlanner.evidence(e, store: store)
        let isWorkspace = e.kind == .workspace
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(e.name).font(.bHeadline).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Tag(text: item.tier.title, tone: item.tier.tone)
                        if let s = e.sources.sorted(by: { $0.rawValue < $1.rawValue }).first { Tag(text: s.rawValue) }
                        Tag(text: (e.size ?? 0).bytesString)
                    }
                }
                if isWorkspace || e.kind == .repo {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.tier.isSafe ? "Why it is safe to clear" : "Check before you clear").font(.bCaption2).foregroundStyle(.secondary)
                        ForEach(proof) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Image(systemName: p.ok ? "checkmark" : "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(p.ok ? AgentColor.good : Brand.reclaimText).frame(width: 14)
                                Text(p.text).font(.bBody).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Note(text: e.note.isEmpty ? item.regret : e.note)
                }
                if !e.artifacts.isEmpty { inside(e) }
                if isWorkspace && item.kind != .buildFolders && !e.artifacts.isEmpty { options(e) }
                Text("The session that made it stays in Traces.").font(.bCaption).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    Button { if !basket.isOn(e, in: item) { basket.tick(e, in: item) } } label: {
                        Text("Add to basket · \(Basket.cost(e, item: item, buildOnly: basket.buildOnly).bytesString)").frame(maxWidth: .infinity)
                    }.buttonStyle(.brandProminent).controlSize(.large).disabled(basket.isOn(e, in: item))
                    Button { store.reveal(e) } label: { Text("Reveal in Finder").frame(maxWidth: .infinity) }.controlSize(.large)
                }
            }.padding(20)
        }.background(Brand.card)
    }

    private func inside(_ e: Entry) -> some View {
        let colors: [Color] = [Brand.ok, AgentColor.codex, Brand.accent, Brand.merged]
        let arts = e.artifacts.sorted { $0.bytes > $1.bytes }
        let rest = max((e.size ?? 0) - e.artifactBytes, 0)
        var parts: [(Double, Color)] = arts.enumerated().map { (Double($1.bytes), colors[$0 % colors.count]) }
        parts.append((Double(rest), Color.secondary.opacity(0.35)))
        return VStack(alignment: .leading, spacing: 8) {
            Text("What is inside").font(.bCaption2).foregroundStyle(.secondary)
            Ladder(parts: parts, height: 10)
            Legend(items: arts.enumerated().map { ("\($1.label) \($1.bytes.bytesString)", colors[$0 % colors.count]) } + [("source \(rest.bytesString)", Color.secondary.opacity(0.5))])
        }
    }

    private func options(_ e: Entry) -> some View {
        let build = basket.buildOnly.contains(e.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text("How much to clear").font(.bCaption2).foregroundStyle(.secondary)
            optionCard("Remove the workspace · \((e.size ?? 0).bytesString)", "Recreate it from \(e.branch ?? "its branch") with one command.", on: !build) { if build { basket.toggleBuildOnly(e) } }
            optionCard("Clear build folders only · \(e.artifactBytes.bytesString)", "Keeps the checkout so you can open it later.", on: build) { if !build { basket.toggleBuildOnly(e) } }
        }
    }

    private func optionCard(_ title: String, _ sub: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.bBody.weight(.semibold))
                Text(sub).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Brand.primaryTint : Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Brand.accent : Brand.border, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
