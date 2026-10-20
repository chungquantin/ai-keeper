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

/// One tool, with its detection status. Used in onboarding and on the Tools page.
struct ToolRow: View {
    let det: Detection
    @Binding var isOn: Bool
    var footprint: Int64?
    var showReveal = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
            Image(systemName: det.spec.symbol).font(.title3).frame(width: 26).foregroundStyle(det.found ? .primary : .tertiary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(det.spec.name).fontWeight(.medium)
                    if det.found { Pill(text: det.running > 0 ? "Detected · \(det.running) running" : "Detected", color: Brand.accent) }
                    else { Pill(text: "Not found", color: .gray) }
                }
                Text(det.spec.blurb).font(.callout).foregroundStyle(.secondary)
                if det.found, !det.evidence.isEmpty {
                    Text(det.evidence + (footprint.map { " · \($0.bytesString) on disk" } ?? "")).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    ForEach(det.spec.capabilities, id: \.self) { c in
                        Text(c).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 1)
                if let n = det.spec.note { Text(n).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
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

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @State private var step = 0
    @State private var picked: Set<String> = []
    @State private var detecting = true
    @State private var roots: [RootChoice] = []
    @State private var findingRoots = true
    @AppStorage("notify") private var notify = true
    @AppStorage("notify.agents") private var notifyAgents = true
    @AppStorage("guard.floorGB") private var floorGB = 50.0
    @AppStorage("budget.daily") private var daily = 0.0

    struct RootChoice: Identifiable { var id: String { path }; let path: String; var repos: Int; var viaTool: Bool; var on: Bool }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: toolsStep
                case 1: foldersStep
                default: alertsStep
                }
            }.frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 640)
        .task { await detect() }
    }

    // MARK: Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if step == 0, let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 52, height: 52) }
                Text(["Pick your tools", "Where do your projects live?", "Stay in the loop"][step]).font(.figure(28))
                Spacer()
                HStack(spacing: 6) { ForEach(0..<3) { Circle().fill(step >= $0 ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) } }
            }
            Text(["We looked for AI coding tools on this Mac and ticked what we found. Add or remove any.",
                  "AI Keeper scans these folders for git repos and their worktrees.",
                  "Tell us when a disk is filling up or an agent is waiting on you."][step])
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            if step == 0 { Button("Look again") { Task { await detect() } }.disabled(detecting) }
            Button(step == 2 ? "Start scanning" : "Continue") {
                if step == 2 { finish() } else { step += 1 }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(step == 0 && picked.isEmpty)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: Step 1: tools

    private var toolsStep: some View {
        let found = store.detections.filter(\.found), other = store.detections.filter { !$0.found }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if detecting { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for tools…").foregroundStyle(.secondary) }.padding(.top, 12) }
                if !found.isEmpty { group("Found on this Mac", found) }
                if !other.isEmpty { group("Not found. Tick one if you use it somewhere we can't see.", other) }
            }.padding(24)
        }
    }

    private func group(_ title: String, _ list: [Detection]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) {
                ForEach(list) { d in
                    ToolRow(det: d, isOn: Binding(get: { picked.contains(d.id) }, set: { on in if on { picked.insert(d.id) } else { picked.remove(d.id) } }),
                            footprint: store.footprints[d.id])
                    if d.id != list.last?.id { Divider() }
                }
            }.panel()
        }
    }

    // MARK: Step 2: folders

    private var foldersStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if findingRoots { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for repos…").foregroundStyle(.secondary) } }
                if roots.isEmpty && !findingRoots {
                    Text("No common project folders found. Add the folder where you keep your repos.").foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach($roots) { $r in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $r.on).toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.path.replacingOccurrences(of: home, with: "~")).fontWeight(.medium)
                                Text("\(r.repos) repo\(r.repos == 1 ? "" : "s")" + (r.viaTool ? " · found through your tools" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.horizontal, 14).padding(.vertical, 10)
                        if r.id != roots.last?.id { Divider() }
                    }
                }.panel().opacity(roots.isEmpty ? 0 : 1)
                Button("Add folder…") {
                    if let p = FolderPicker.choose(message: "Choose a folder that contains your git repositories"), !roots.contains(where: { $0.path == p }) {
                        roots.append(RootChoice(path: p, repos: ProjectRoots.repoCount(p), viaTool: false, on: true))
                    }
                }
            }.padding(24)
        }
    }

    // MARK: Step 3: alerts

    private var alertsStep: some View {
        Form {
            Toggle("Notify me when a coding agent needs me or finishes", isOn: $notifyAgents)
            Toggle("Notify me when disk space runs low", isOn: $notify)
            Stepper(value: $floorGB, in: 5...500, step: 5) { Text("Low-disk alert at **\(Int(floorGB)) GB** free") }
            Stepper(value: $daily, in: 0...1000, step: 5) { Text("Daily AI spend alert: **\(daily == 0 ? "off" : String(format: "$%.0f", daily))**") }
            Text("macOS will ask once to allow notifications. Change any of this later in Settings.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).scrollDisabled(true).padding(.top, 8)
    }

    // MARK: Actions

    private func detect() async {
        detecting = true
        await store.detectTools()
        if picked.isEmpty { picked = Set(store.detections.filter(\.found).map(\.id)) }
        detecting = false
        findingRoots = true
        let list = await Task.detached { ToolCatalog.detectProjectRoots() }.value
        roots = list.map { RootChoice(path: $0.path, repos: $0.repos, viaTool: $0.viaTool, on: true) }
        findingRoots = false
    }

    private func finish() {
        store.enabledTools = picked
        store.repoRoots = roots.filter(\.on).map(\.path)
        Notifier.requestPermission()
        Task { await store.finishOnboarding() }
    }
}

enum ProjectRoots {
    static func repoCount(_ dir: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { FileManager.default.fileExists(atPath: "\(dir)/\($0)/.git") }.count
    }
}

// MARK: - Tools page

struct ToolsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let found = store.detections.filter(\.found), other = store.detections.filter { !$0.found }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if store.toolsChanged {
                    HStack {
                        Label("Tool selection changed.", systemImage: "arrow.triangle.2.circlepath").fontWeight(.medium)
                        Spacer()
                        Button("Rescan now") { Task { store.toolsChanged = false; store.loadUsage(); await store.rescan() } }.buttonStyle(.borderedProminent)
                    }.padding(14).background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
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
                                    Text("\(ProjectRoots.repoCount(r)) repos").font(.caption).foregroundStyle(.secondary)
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
            }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Tools")
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
