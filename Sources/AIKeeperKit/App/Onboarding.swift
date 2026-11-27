import AppKit
import SwiftUI

enum FolderPicker {
    @MainActor static func choose(message: String) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = message
        p.prompt = "Add folder"
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

/// One tool, with its detection status. Used in onboarding and under Agents, Tools.
struct ToolRow: View {
    let det: Detection
    @Binding var isOn: Bool
    var footprint: Int64?
    var showReveal = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
            ToolIcon(id: det.spec.id, fallback: det.spec.symbol, size: 24).foregroundStyle(det.found ? .primary : .tertiary)
                .opacity(det.found ? 1 : 0.55).frame(width: 26).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(det.spec.name).fontWeight(.medium)
                    if det.found { Pill(text: det.running > 0 ? "Detected · \(det.running) running" : "Detected", color: Brand.accent) }
                    else { Pill(text: "Not found", color: .gray) }
                }
                Text(det.spec.blurb).font(.bCallout).foregroundStyle(.secondary)
                if det.found, !det.evidence.isEmpty {
                    Text(det.evidence + (footprint.map { " · \($0.bytesString) on disk" } ?? "")).font(.bCaption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    ForEach(det.spec.capabilities, id: \.self) { c in
                        Text(c).font(.bCaption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 1)
                if let n = det.spec.note { Text(n).font(.bCaption).foregroundStyle(Brand.reclaimText).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            if showReveal, let d = det.dataPath {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d)]) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(isOn || det.found ? 1 : 0.7)
    }
}

// MARK: - First run

/// Three screens: what we read and what we never touch, which agents to watch, then the first result.
struct OnboardingView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var step = 0
    @State private var picked: Set<String> = []
    @State private var roots: [String] = []
    @State private var detecting = true
    @State private var scanStarted = Date()
    @AppStorage(Prefs.Key.showMenuBar) private var showMenuBar = true

    private var scanDone: Bool { step == 2 && !store.isScanning && (store.lastScan.map { $0 >= scanStarted } ?? false) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: agents
                default: result
                }
            }
            .padding(.horizontal, 36).padding(.top, 36).frame(maxHeight: .infinity, alignment: .top)
            dots.padding(.vertical, 18)
        }
        .frame(width: 560, height: 680)
        .task { await detect() }
    }

    private var dots: some View {
        HStack(spacing: 6) { ForEach(0..<3) { Circle().fill($0 == step ? Brand.accent : Brand.mutedForeground.opacity(0.3)).frame(width: 6, height: 6) } }
            .accessibilityLabel("Step \(step + 1) of 3")
    }

    // MARK: 1. Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            TierChip(symbol: "shield", tone: .blue, size: 56)
            Text("Keep your Mac and your coding agents tidy").font(.system(size: 26, weight: .semibold)).tracking(-0.7).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                point("trash", .green, "Get space back", "Old worktrees and build folders, sorted by what losing them would cost.")
                point("chart.bar", .blue, "See what agents cost", "Spend per day and per agent, with a budget you set.")
                point("bolt.horizontal", .violet, "Understand how you work", "Every session as a trace you can search and compare.")
            }.padding(.top, 4)
            Spacer(minLength: 0)
            Note(text: "Private by design. AI Keeper reads agent logs on this Mac. Nothing leaves it.")
            Button { step = 1 } label: { Text("Continue").frame(maxWidth: .infinity) }.buttonStyle(.brandProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    private func point(_ symbol: String, _ tone: Tone, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TierChip(symbol: symbol, tone: tone, size: 28)
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.bBody.weight(.semibold)); Text(text).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: 2. Agents

    private var agents: some View {
        let list = store.detections.sorted { ($0.found ? 0 : 1, $0.spec.name) < ($1.found ? 0 : 1, $1.spec.name) }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which agents do you use?").font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                Text("We found these on this Mac. Turn off any you want us to ignore.").font(.bCallout).foregroundStyle(.secondary)
            }
            if detecting { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for agents…").foregroundStyle(.secondary) } }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { d in
                        HStack(spacing: 12) {
                            ToolIcon(id: d.spec.id, fallback: d.spec.symbol, size: 24).frame(width: 26).opacity(d.found ? 1 : 0.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.spec.name).font(.bBody.weight(.medium))
                                Text(d.found ? (store.footprints[d.id].map { "\($0.bytesString) on disk" } ?? d.evidence) : "Not found").font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { picked.contains(d.id) }, set: { on in if on { picked.insert(d.id) } else { picked.remove(d.id) } })).toggleStyle(.switch).labelsHidden()
                        }.padding(.horizontal, 14).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
                    }
                }
            }.panel().frame(maxHeight: 300)
            if !roots.isEmpty { Text(foldersLine).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 4) {
                Text("We never touch").font(.bCaption2).foregroundStyle(.secondary)
                Text("Uncommitted changes, unpushed commits, or a folder an agent has open. Everything we remove can be put back from History.").font(.bCaption).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 0)
            Button { startScan() } label: { Text("Scan this Mac").frame(maxWidth: .infinity) }
                .buttonStyle(.brandProminent).controlSize(.large).disabled(picked.isEmpty).keyboardShortcut(.defaultAction)
            Button("Back") { step = 0 }.buttonStyle(.plain).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var foldersLine: String {
        let shown = roots.prefix(3).map { $0.replacingOccurrences(of: home, with: "~") }.joined(separator: ", ")
        let more = roots.count > 3 ? " and \(roots.count - 3) more" : ""
        return "Project folders: \(shown)\(more). Change them later in Settings."
    }

    // MARK: 3. The first result

    private var result: some View {
        let st = store.stats, safe = st.safeBytes, parts = safe.byteParts
        let tiers: [(Tier, Int64)] = [(.rebuildable, st.rebuildBytes), (.onRemote, st.remoteBytes), (.onlyHere, st.onlyHereBytes)]
        return VStack(alignment: .leading, spacing: 16) {
            if !scanDone {
                Spacer()
                VStack(spacing: 14) {
                    RobotSpinner().scaleEffect(2).frame(height: 44)
                    Text("Scanning this Mac").font(.system(size: 22, weight: .semibold))
                    if case .measuring(let d, let t) = store.phase {
                        ProgressView(value: Double(d), total: Double(max(t, 1))).frame(width: 240)
                        Text("Measuring \(d) of \(t)").font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                    } else { Text("Finding your workspaces…").font(.bCaption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                Text("Scan finished in \(max(1, Int((store.lastScan ?? Date()).timeIntervalSince(scanStarted)))) seconds").font(.bCaption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(parts.number).font(.system(size: 72, weight: .semibold)).tracking(-2).monospacedDigit()
                        Text(parts.unit).font(.system(size: 26, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(safe > 0 ? "you can get back without losing any work." : "is safe to clear right now. Nothing to do yet.").font(.system(size: 15))
                }
                Ladder(parts: tiers.map { (Double($0.1), $0.0.color) }, label: tiers.map { "\($0.0.title) \($0.1.bytesString)" }.joined(separator: ", "))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tiers, id: \.0.id) { t, b in
                        HStack(spacing: 8) { Circle().fill(t.color).frame(width: 7, height: 7); Text("\(t.title) \(b.bytesString)" + (t == .onlyHere && b > 0 ? " · look first" : "")).font(.bCaption).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 0)
                Toggle("Show AI Keeper in the menu bar", isOn: $showMenuBar).toggleStyle(.checkbox)
                if safe > 0 {
                    Button { finish(); store.basket.resetToSafe(); nav.showBasket = true } label: { Text("Reclaim \(safe.bytesString)").frame(maxWidth: .infinity) }
                        .buttonStyle(.brandProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    Button("Review first") { finish(); nav.go(.review) }.buttonStyle(.plain).foregroundStyle(Brand.primaryText).frame(maxWidth: .infinity)
                } else {
                    Button { finish() } label: { Text("Open AI Keeper").frame(maxWidth: .infinity) }.buttonStyle(.brandProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: Actions

    private func detect() async {
        detecting = true
        await store.detectTools()
        if picked.isEmpty { picked = Set(store.detections.filter(\.found).map(\.id)) }
        detecting = false
        let list = await Task.detached { ToolCatalog.detectProjectRoots() }.value
        roots = list.map(\.path)
    }

    private func startScan() {
        store.enabledTools = picked
        if !roots.isEmpty { store.repoRoots = roots }
        scanStarted = Date(); step = 2
        Notifier.requestPermission()
        Task { await store.startFirstScan() }
    }

    private func finish() { store.completeOnboarding() }
}

enum ProjectRoots {
    static func repoCount(_ dir: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { FileManager.default.fileExists(atPath: "\(dir)/\($0)/.git") }.count
    }
}

// MARK: - Tools (Agents, Detect and choose tools)

struct ToolsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let found = store.detections.filter(\.found), other = store.detections.filter { !$0.found }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if store.toolsChanged {
                    HStack {
                        Label("Tool selection changed.", systemImage: "arrow.triangle.2.circlepath").fontWeight(.medium)
                        Spacer()
                        Button("Rescan now") { Task { store.toolsChanged = false; store.loadUsage(); await store.rescan() } }.buttonStyle(.brandProminent)
                    }.padding(14).background(Brand.reclaim.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
                section("On this Mac", found)
                if !other.isEmpty { section("Not found", other) }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Project folders")
                    VStack(spacing: 0) {
                        ForEach(store.repoRoots, id: \.self) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.replacingOccurrences(of: home, with: "~")).fontWeight(.medium)
                                    Text("\(ProjectRoots.repoCount(r)) repos").font(.bCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { store.repoRoots.removeAll { $0 == r }; store.toolsChanged = true } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove folder").accessibilityLabel("Remove folder")
                            }.padding(.horizontal, 14).padding(.vertical, 9)
                            Divider()
                        }
                        Button("Add folder…") {
                            if let p = FolderPicker.choose(message: "Choose a folder that contains your git repositories"), !store.repoRoots.contains(p) {
                                store.repoRoots.append(p); store.toolsChanged = true
                            }
                        }.padding(12)
                    }.panel()
                }
                HStack {
                    Button("Run setup again") { store.needsOnboarding = true }
                    Button("Look for tools again") { Task { await store.detectTools() } }
                }
            }.padding(28).frame(maxWidth: 1240, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if store.detections.isEmpty { await store.detectTools() } }
    }

    private func section(_ title: String, _ list: [Detection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: title)
            VStack(spacing: 0) {
                ForEach(list) { d in
                    ToolRow(det: d, isOn: Binding(get: { store.enabledTools.contains(d.id) },
                                                  set: { on in
                                                      if on { store.enabledTools.insert(d.id) } else { store.enabledTools.remove(d.id) }
                                                      store.toolsChanged = true
                                                  }),
                            footprint: store.footprints[d.id], showReveal: true)
                    if d.id != list.last?.id { Divider() }
                }
            }.panel()
        }
    }
}
