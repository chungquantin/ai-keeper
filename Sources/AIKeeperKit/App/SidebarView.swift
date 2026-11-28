import SwiftUI

/// The quick action that lives in the sidebar on every page: what is safe to clear, one button to clear it, one to rescan.
struct ReclaimCard: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket

    var body: some View {
        let safe = store.stats.safeBytes
        let parts = safe.byteParts
        VStack(alignment: .leading, spacing: 9) {
            Button { nav.go(.area(.cleanup, .overview)) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(low ? "Macintosh HD is almost full" : "Macintosh HD").font(.bCaption2).foregroundStyle(low ? Brand.reclaimText : .secondary); Spacer()
                        Text("\(store.disk.available.bytesString) free").font(.bCaption2.weight(.semibold)).foregroundStyle(low ? Brand.reclaimText : .primary) }
                    StorageBar(disk: store.disk, segments: store.storage.segments(store.disk), height: 6)
                }
            }.buttonStyle(.plain).help("See what is using your storage")
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.bCaption2).foregroundStyle(.secondary)
                Spacer()
                status
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.hasData ? parts.number : "—").font(.figure(26)).monospacedDigit()
                Text(store.hasData ? parts.unit : "").font(.figure(12)).foregroundStyle(.secondary)
            }
            if case .measuring(let d, let t) = store.phase { ProgressView(value: Double(d), total: Double(max(t, 1))).controlSize(.small) }
            HStack(spacing: 6) {
                if safe == 0 && store.hasData && !store.isScanning {
                    Button { nav.go(.review) } label: { Text("Review").frame(maxWidth: .infinity) }.buttonStyle(.brandOutline)
                } else {
                    Button { basket.resetToSafe(); nav.showBasket = true } label: { Text("Reclaim").frame(maxWidth: .infinity) }
                        .buttonStyle(.brandProminent).disabled(safe == 0 || store.isScanning)
                }
                Button { Task { await store.rescan() } } label: { Image(systemName: "arrow.clockwise").frame(width: 14) }
                    .buttonStyle(.brandOutline).disabled(store.isScanning).help("Rescan (⌘R)").accessibilityLabel("Rescan")
            }.controlSize(.regular)
        }
        .padding(12).panel(12)
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
    }

    private var low: Bool { store.disk.total > 0 && Double(store.disk.available) / Double(store.disk.total) < 0.08 }

    private var title: String {
        switch store.phase {
        case .discovering: "Finding workspaces"
        case .measuring(let d, let t): "Measuring \(d) of \(t)"
        default: store.stats.safeBytes == 0 && store.hasData ? "Tidy" : "Safe to reclaim"
        }
    }

    @ViewBuilder private var status: some View {
        if store.isScanning { RobotSpinner() }
        else {
            let stale = store.lastScan.map { Date().timeIntervalSince($0) > 3600 } ?? true
            HStack(spacing: 4) {
                Circle().fill(stale ? Brand.reclaim : Brand.ok).frame(width: 6, height: 6)
                Text(store.lastScan.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) } ?? "not scanned").font(.bCaption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 44)   // the traffic lights sit here
            scopePicker
            sidebarList
            ActivityBar()
            ReclaimCard()
        }
    }

    /// The agent filter replaces the old "By tool" list. Pages that can narrow to one agent follow it.
    private var scopePicker: some View {
        Menu {
            Button("All agents") { nav.scope = nil }
            Divider()
            ForEach(ToolCatalog.all.filter { store.enabledTools.contains($0.id) && ($0.agents || $0.usage || $0.workspaces) }, id: \.id) { t in
                Button(t.name) { nav.scope = t.id }
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(nav.scope.map { AgentColor.of($0) } ?? Brand.accent).frame(width: 8, height: 8)
                Text(nav.scope.flatMap { id in ToolCatalog.all.first { $0.id == id }?.name } ?? "All agents").font(.brand(13, .medium))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.border))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
        .accessibilityLabel("Agent filter")
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Area.allCases) { a in row(a) }
                Divider().padding(.vertical, 8).padding(.horizontal, 10)
                Button { nav.showPalette = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").frame(width: 18)
                        Text("Search")
                        Spacer()
                        Text("⌘K").font(.bCaption)
                    }
                    .foregroundStyle(Brand.mutedForeground).padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                }.buttonStyle(HoverRowStyle()).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.padding(.horizontal, 10).padding(.top, 6)
        }
        .font(.bBody)
    }

    /// A quiet tint and cobalt text mark the open area. The solid cobalt row is kept for the one primary button per screen.
    private func row(_ a: Area) -> some View {
        let on = nav.area == a
        return Button { nav.open(a) } label: {
            HStack(spacing: 10) {
                Image(systemName: a.symbol).font(.system(size: 13, weight: .regular)).frame(width: 18)
                    .foregroundStyle(on ? Brand.primaryText : Brand.mutedForeground)
                Text(a.rawValue).font(.brand(13, on ? .semibold : .regular))
                Spacer(minLength: 4)
                if let b = badge(a) {
                    let hot = a == .agents && b.contains("needs")
                    Text(b).font(.brand(11, hot ? .semibold : .medium)).monospacedDigit()
                        
                        .foregroundStyle(hot ? Brand.reclaimText : Brand.mutedForeground)
                }
            }
            .foregroundStyle(on ? Brand.primaryText : Color.primary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(on ? Brand.primaryTint : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func badge(_ a: Area) -> String? {
        switch a {
        case .today: return nil
        case .sessions:
            let n = store.agents.filter { $0.kind != .mcp }.count
            return n > 0 ? "\(n) live" : nil
        case .insights: return nil
        case .cleanup: return store.hasData && store.reclaimable > 0 ? store.reclaimable.bytesString : nil
        case .agents:
            let waiting = store.agents.filter { $0.state == .needsInput && $0.kind != .mcp }.count
            if waiting > 0 { return "\(waiting) needs you" }
            let review = store.skills.filter { let v = SkillLibrary.verdict($0, store.skillScans); return v == .caution || v == .danger }.count
            return review > 0 ? "\(review) to review" : nil
        }
    }
}
