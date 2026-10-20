import SwiftUI

extension Entry {
    var statusPill: (String, Color) {
        if kind == .repo { return ("Main checkout", .blue) }
        if verdict == .dangling { return ("Stale record", .gray) }
        if safety == .danger { return ("Uncommitted", .red) }
        if verdict == .deprecated { return safety == .caution ? ("Review first", .orange) : ("Safe to remove", .green) }
        if safety == .caution { return ("Local commits", .blue) }
        return measured ? ("Active", .blue) : ("Measuring", .gray)
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: Store
    let go: (Section) -> Void
    let explore: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Category: Identifiable {
        let id: String
        let title: String
        let detail: String
        let color: Color
        let bytes: Int64
        let section: Section
    }

    private var categories: [Category] {
        let artifactWS = store.workspaces.filter { $0.verdict != .deprecated && !$0.artifacts.isEmpty }.count
        return [
            Category(id: "ws", title: "Deprecated workspaces",
                     detail: "\(store.removableWorkspaces.count) archived, merged or idle", color: .green,
                     bytes: store.total(store.removableWorkspaces), section: .deprecated),
            Category(id: "art", title: "Build folders",
                     detail: "node_modules, target, .next in \(artifactWS) active workspaces", color: .orange,
                     bytes: store.keptArtifactBytes, section: .all),
            Category(id: "ses", title: "Orphaned chat history",
                     detail: "\(store.orphanSessions.count) Claude projects whose folder is gone", color: .teal,
                     bytes: store.total(store.orphanSessions), section: .leftovers),
            Category(id: "cache", title: "Caches and logs",
                     detail: "\(store.caches.count) locations, rebuilt automatically", color: .gray,
                     bytes: store.total(store.caches), section: .leftovers),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                scanBar
                hero
                StorageMapView(explore: explore, open: go)
                FreeSpaceChart()
                breakdown
                repos
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Rescan

    /// Rescan is the one control for "bring everything up to date": workspaces, pull requests and the disk map.
    private var scanBar: some View {
        HStack(spacing: 12) {
            Group {
                if store.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if case .measuring(let d, let t) = store.phase { Text("Scanning workspaces · \(d) of \(t)").monospacedDigit() } else { Text("Finding workspaces…") }
                    }
                } else {
                    Text("Workspaces scanned " + (store.lastScan.map { $0.formatted(.relative(presentation: .named)) } ?? "never"))
                }
            }.font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await store.rescan() } } label: { Label(store.isScanning ? "Scanning…" : "Rescan everything", systemImage: "arrow.clockwise") }
                .disabled(store.isScanning || store.mapRefreshing)
                .help("Rescan workspaces, pull requests and the disk map (⌘R)")
        }
    }

    // MARK: Hero

    private var hero: some View {
        let parts = store.hasData ? store.reclaimable.byteParts : (number: "—", unit: "")
        return VStack(alignment: .leading, spacing: 10) {
            Text(store.isScanning ? "Measuring your workspaces…" : "You can get back")
                .font(.title3).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parts.number).font(.figure(88, .medium)).monospacedDigit()
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .smooth, value: store.reclaimable)
                Text(parts.unit).font(.figure(34, .regular)).foregroundStyle(.secondary)
            }
            .minimumScaleFactor(0.6).lineLimit(1)
            Text(heroSummary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if store.keptArtifactBytes > 0 {
                    Button("Clean build folders · \(store.keptArtifactBytes.bytesString)") {
                        store.propose(.purgeArtifacts, for: store.buildHolders)
                    }.buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                }
                if !store.removableWorkspaces.isEmpty {
                    Button("Review \(store.removableWorkspaces.count) deprecated workspaces") {
                        store.propose(.removeWorkspaces, for: store.removableWorkspaces)
                    }.controlSize(.large)
                }
                Button("Browse all") { go(.all) }.controlSize(.large)
            }.padding(.top, 6)
        }
    }

    private var heroSummary: String {
        guard store.hasData else { return "Measuring your workspaces. Numbers fill in as they come." }
        guard let a = store.stats.biggestArtifact else {
            return "\(store.workspaces.count) workspaces take \(store.managedBytes.bytesString)."
        }
        return "Mostly build output. The largest is \(a.holder)/\(a.label) at \(a.bytes.bytesString). It is regenerated by your next build."
    }

    // MARK: Breakdown

    private var breakdown: some View {
        let cats = categories
        let total = Double(max(cats.reduce(0) { $0 + $1.bytes }, 1))
        return VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(cats) { c in
                        Rectangle().fill(c.color.opacity(0.9))
                            .frame(width: max(0, (geo.size.width - 6) * Double(c.bytes) / total))
                    }
                }
                .clipShape(Capsule())
                .background(Capsule().fill(.quaternary))
            }.frame(height: 10)

            VStack(spacing: 0) {
                ForEach(cats) { c in
                    Button { go(c.section) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(c.color).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).fontWeight(.medium)
                                Text(c.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(c.bytes.bytesString).monospacedDigit().font(.body)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }.buttonStyle(HoverRowStyle())
                    if c.id != cats.last?.id { Divider().padding(.leading, 37) }
                }
            }
            .panel()
        }
    }

    // MARK: Disk

    private var disk: some View {
        let d = store.disk
        let total = Double(max(d.total, 1))
        let managed = Double(store.managedBytes)
        let reclaim = Double(store.reclaimable)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "This Mac", trailing: "\(d.available.bytesString) free of \(d.total.bytesString)")
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 2) {
                    Rectangle().fill(.secondary.opacity(0.35)).frame(width: w * max(0, Double(d.used) - managed) / total)
                    Rectangle().fill(.secondary.opacity(0.75)).frame(width: w * max(0, managed - reclaim) / total)
                    Rectangle().fill(Color.green).frame(width: w * reclaim / total)
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .background(Capsule().fill(.quaternary))
            }.frame(height: 10)
            HStack(spacing: 18) {
                legend(.secondary.opacity(0.35), "Everything else")
                legend(.secondary.opacity(0.75), "Workspaces you keep")
                legend(.green, "Reclaimable")
            }.font(.caption)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 7, height: 7); Text(t).foregroundStyle(.secondary) }
    }

    // MARK: Repos

    private var repos: some View {
        let groups = store.stats.repoGroups
        let maxV = Double(groups.first?.total ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Largest repositories")
            VStack(spacing: 0) {
                ForEach(groups) { g in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).fontWeight(.medium).lineLimit(1)
                            Text("\(g.count) workspace\(g.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 190, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.secondary.opacity(0.55)).frame(width: geo.size.width * Double(g.total) / maxV)
                                Capsule().fill(Color.green).frame(width: geo.size.width * Double(g.reclaim) / maxV)
                            }.frame(maxHeight: .infinity)
                        }.frame(height: 18)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(g.total.bytesString).monospacedDigit()
                            Text(g.reclaim > 0 ? "−\(g.reclaim.bytesString)" : " ").font(.caption).foregroundStyle(.green).monospacedDigit()
                        }.frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    if g.name != groups.last?.name { Divider() }
                }
            }.panel()
        }
    }
}
