import SwiftUI

extension SkillVerdict {
    var color: Color { [Brand.accent, .orange, .red, .gray][rawValue] }
    var symbol: String { ["checkmark.shield", "exclamationmark.triangle", "xmark.shield", "questionmark.circle"][rawValue] }
}

/// Every skill your agents can load, with a security scan from NVIDIA SkillSpector.
struct SkillsView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var tool = "All tools"
    @State private var filter = 0                 // 0 all · 1 worth a look · 2 not scanned
    @State private var selection: Set<String> = []
    @State private var pendingRemove: [SkillInfo]?
    @State private var showRemoved = false
    @State private var confirmInstall = false
    @State private var notice: String?

    private func verdict(_ s: SkillInfo) -> SkillVerdict { SkillLibrary.verdict(s, store.skillScans) }

    private var tools: [String] { ["All tools"] + Array(Set(store.skills.flatMap(\.tools))).sorted() }

    private var rows: [SkillInfo] {
        store.skills.filter { s in
            (tool == "All tools" || s.tools.contains(tool))
                && (filter == 0 || (filter == 1 && (verdict(s) == .caution || verdict(s) == .danger)) || (filter == 2 && verdict(s) == .unscanned))
                && (query.isEmpty || s.name.localizedCaseInsensitiveContains(query) || s.description.localizedCaseInsensitiveContains(query) || (s.plugin ?? "").localizedCaseInsensitiveContains(query))
        }.sorted { (SkillLibrary.sortKey(verdict($0)), $0.name.lowercased()) < (SkillLibrary.sortKey(verdict($1)), $1.name.lowercased()) }
    }

    private var unscanned: [SkillInfo] { store.skills.filter { SkillScanner.current($0, in: store.skillScans) == nil } }
    private var selected: SkillInfo? { selection.count == 1 ? store.skills.first { $0.id == selection.first } : nil }
    private var chosen: [SkillInfo] { store.skills.filter { selection.contains($0.id) } }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            controls(rows.count)
            Divider()
            if store.skillScanner == nil && store.skillsLoaded { scannerBanner; Divider() }
            HStack(spacing: 0) {
                List(rows, selection: $selection) { s in
                    SkillRow(skill: s, verdict: verdict(s), score: SkillScanner.current(s, in: store.skillScans)?.score).tag(s.id)
                        .contextMenu { Button("Move to quarantine…") { pendingRemove = selection.contains(s.id) ? chosen : [s] } }
                }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .overlay {
                        if rows.isEmpty {
                            ContentUnavailableView(store.skillsLoaded ? "No skills match" : "Looking for skills…", systemImage: "checkmark.shield",
                                                   description: Text(store.skills.isEmpty && store.skillsLoaded ? "Skills live in folders like ~/.claude/skills and ~/.agents/skills." : ""))
                        }
                    }
                if let s = selected {
                    Divider()
                    SkillDetail(skill: s, confirmInstall: $confirmInstall).id(s.id).frame(width: 440)
                }
            }
            if !selection.isEmpty { Divider(); actionBar }
            footnote
        }
        .navigationTitle("Skills")
        .searchable(text: $query, prompt: "Search skills")
        .task { await store.loadSkills(); if let r = store.requestedSkill { selection = [r]; store.requestedSkill = nil } }
        .onChange(of: store.requestedSkill) { _, r in if let r { selection = [r]; store.requestedSkill = nil } }
        .confirmationDialog("Install NVIDIA SkillSpector?", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Install") { Task { notice = await store.installScanner() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs \(SkillScanner.installCommand). It downloads SkillSpector \(SkillScanner.pinnedRef) and its dependencies from the internet, and Python 3.12 if you don't have it. AI Keeper does not bundle it. Needs uv.")
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }), titleVisibility: .visible) {
            Button("Move to quarantine") { remove(permanent: false) }
            Button("Delete permanently", role: .destructive) { remove(permanent: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(removeMessage) }
        .sheet(isPresented: $showRemoved) { QuarantineSheet().environmentObject(store) }
        .alert("SkillSpector", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") {} } message: { Text(notice ?? "") }
    }

    private func controls(_ count: Int) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) { Text("All").tag(0); Text("Worth a look").tag(1); Text("Not scanned").tag(2) }
                .pickerStyle(.segmented).frame(width: 290).labelsHidden()
            Picker("", selection: $tool) { ForEach(tools, id: \.self) { Text($0).tag($0) } }.frame(width: 140).labelsHidden()
            Button("Select high risk") { selection = Set(rows.filter { verdict($0) == .danger }.map(\.id)) }
                .disabled(!rows.contains { verdict($0) == .danger }).help("Selects every skill rated Do not install, so you can read them and remove them together")
            Spacer()
            if !store.quarantinedSkills.isEmpty { Button("Removed (\(store.quarantinedSkills.count))") { showRemoved = true }.help("Skills you took out of use. You can restore them.") }
            if let p = store.skillScanProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 120)
                Text("Scanning \(p.done) of \(p.total)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Stop") { store.stopSkillScan() }.help("Stops the scan. Finished skills keep their result.")
            } else {
                Text("\(count) skills").font(.callout).foregroundStyle(.secondary)
                Button(unscanned.isEmpty ? "Rescan all" : "Scan \(unscanned.count) new") {
                    Task { await store.scanSkills(unscanned.isEmpty ? store.skills : unscanned) }
                }
                .disabled(store.skillScanner == nil || store.skills.isEmpty)
                .help(store.skillScanner == nil ? "Install SkillSpector first" : "Scans skills that are new or changed. Unchanged ones keep their result.")
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected").font(.callout.weight(.medium))
            Button("Clear") { selection = [] }.controlSize(.small)
            Spacer()
            Text("Moves them to a quarantine you can restore from").font(.caption).foregroundStyle(.secondary)
            Button("Remove…", role: .destructive) { pendingRemove = chosen }
        }.padding(.horizontal, 16).padding(.vertical, 8).background(.quaternary.opacity(0.4))
    }

    private var removeTitle: String { let n = SkillRemoval.plan(pendingRemove ?? []).removable.count; return n == 0 ? "Nothing here can be removed" : "Remove \(n) skill\(n == 1 ? "" : "s")?" }

    private var removeMessage: String {
        let plan = SkillRemoval.plan(pendingRemove ?? [])
        var m = plan.removable.prefix(6).map(\.name).joined(separator: ", ") + (plan.removable.count > 6 ? " and \(plan.removable.count - 6) more" : "")
        m += ". They are moved to a quarantine, with the links other tools use, and Removed lets you restore them. Scanner findings are heuristics, so check the ones you are unsure about first."
        if !plan.skipped.isEmpty { m += " Left alone: \(plan.skipped.count) (plugin or project skills, which are not removed from here)." }
        return m
    }

    private func remove(permanent: Bool) {
        guard let list = pendingRemove else { return }
        let r = store.removeSkills(list, permanent: permanent)
        selection = []
        notice = r.failed == 0 ? "Removed \(r.done) skill\(r.done == 1 ? "" : "s")." + (permanent ? "" : " Restore them from Removed.") : "Removed \(r.done), \(r.failed) failed."
        Task { await store.loadSkills() }
    }

    private var scannerBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan these skills for security risks").font(.callout.weight(.medium))
                Text("Uses NVIDIA SkillSpector, which isn't installed yet. It looks for prompt injection, data exfiltration, risky scripts and more.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.skillInstalling ? "Installing…" : "Install SkillSpector…") { confirmInstall = true }.disabled(store.skillInstalling)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.quaternary.opacity(0.4))
    }

    private var footnote: some View {
        HStack(spacing: 4) {
            Text("Scans are static: nothing in a skill is sent to a language model. SkillSpector checks the dependencies a skill lists against OSV.dev. Findings are heuristics, not verdicts.")
            Link("About SkillSpector", destination: URL(string: SkillScanner.projectURL)!)
        }
        .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SkillRow: View {
    let skill: SkillInfo
    let verdict: SkillVerdict
    let score: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.color).frame(width: 20).accessibilityLabel(verdict.label)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(skill.name).lineLimit(1)
                    if skill.hasScripts { Text("scripts").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()).foregroundStyle(.secondary) }
                }
                Text(skill.description.isEmpty ? "No description" : skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(skill.tools.joined(separator: ", ") + (skill.scope == .plugin ? " · plugin" : ""))
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            Text(verdict == .unscanned ? "Not scanned" : verdict.label).font(.caption).foregroundStyle(verdict == .danger ? Color.red : .secondary).frame(width: 92, alignment: .trailing)
            Text(score.map { "\($0)" } ?? "").monospacedDigit().foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct SkillDetail: View {
    @EnvironmentObject var store: Store
    let skill: SkillInfo
    @Binding var confirmInstall: Bool

    private var scan: SkillScan? { SkillScanner.current(skill, in: store.skillScans) }
    private var scanning: Bool { store.skillScanProgress != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(skill.tools.joined(separator: ", ") + (skill.plugin.map { " · plugin \($0)" + (skill.pluginVersion.map { " \($0)" } ?? "") } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !skill.description.isEmpty { Text(skill.description).textSelection(.enabled) }
                facts
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.realPath)]) }
                    Button("Open SKILL.md") { NSWorkspace.shared.open(URL(fileURLWithPath: skill.realPath + (FileManager.default.fileExists(atPath: skill.realPath + "/SKILL.md") ? "/SKILL.md" : "/skill.md"))) }
                }.controlSize(.small)
                Divider()
                scanSection
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow { Text("Location").foregroundStyle(.secondary); Text(Fmt.tilde(skill.realPath)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            GridRow { Text("Contents").foregroundStyle(.secondary); Text("\(skill.files) files, \(skill.bytes.bytesString)" + (skill.hasScripts ? ", includes scripts" : "")) }
            GridRow { Text("Changed").foregroundStyle(.secondary); Text(skill.modified.formatted(.relative(presentation: .named))) }
            if skill.locations.count > 1 { GridRow(alignment: .top) { Text("Linked from").foregroundStyle(.secondary); Text(skill.locations.map(Fmt.tilde).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
        }.font(.callout)
    }

    @ViewBuilder private var scanSection: some View {
        if let c = scan {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: c.verdict.symbol).font(.title).foregroundStyle(c.verdict.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.verdict.label).font(.headline)
                    Text("Score \(c.score) of 100 · SkillSpector \(c.scannerVersion) · \(c.scannedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan again") { Task { await store.scanSkills([skill]) } }.controlSize(.small).disabled(scanning || store.skillScanner == nil)
            }
            if !c.complete { Label("The scan couldn't inspect everything, so a clean result isn't a guarantee.", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
            if c.issues.isEmpty { Text("No findings.").foregroundStyle(.secondary) }
            ForEach(Array(c.issues.prefix(40).enumerated()), id: \.element.id) { i, issue in IssueCard(issue: issue, expanded: i == 0) }
            if c.issues.count > 40 { Text("And \(c.issues.count - 40) more. Run keeper skills show \(skill.name) --json for all of them.").font(.caption).foregroundStyle(.secondary) }
            if !c.issues.isEmpty { Text("Findings are heuristics. Read the lines they point at before you decide.").font(.caption).foregroundStyle(.tertiary) }
        } else if let err = store.skillErrors[skill.realPath] {
            Label(err, systemImage: "xmark.octagon").foregroundStyle(.red)
            Button("Try again") { Task { await store.scanSkills([skill]) } }.disabled(scanning)
        } else if store.skillScanner == nil {
            VStack(alignment: .leading, spacing: 10) {
                Label("Not scanned", systemImage: "questionmark.circle").font(.headline)
                Text("Install NVIDIA SkillSpector to check this skill for prompt injection, data exfiltration and risky scripts.").foregroundStyle(.secondary)
                Button("Install SkillSpector…") { confirmInstall = true }.disabled(store.skillInstalling)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Not scanned", systemImage: "questionmark.circle").font(.headline)
                Button(scanning ? "Scanning…" : "Scan this skill") { Task { await store.scanSkills([skill]) } }.disabled(scanning)
            }
        }
    }
}

struct IssueCard: View {
    let issue: SkillIssue
    @State var expanded: Bool

    init(issue: SkillIssue, expanded: Bool) { self.issue = issue; _expanded = State(initialValue: expanded) }

    private var color: Color { issue.rank >= 3 ? .red : issue.rank == 2 ? .orange : .secondary }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(issue.file)\(issue.line > 0 ? ":\(issue.line)" : "")").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if !issue.explanation.isEmpty { Text(issue.explanation).font(.callout).textSelection(.enabled) }
                if let code = issue.snippet, !code.isEmpty {
                    Text(code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(10)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                if !issue.remediation.isEmpty { Text("Fix: \(issue.remediation)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(issue.finding.isEmpty ? issue.category : issue.finding).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(issue.severity.capitalized) · \(issue.rule) · \(Int(issue.confidence * 100))%").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct QuarantineSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Removed skills").font(.title3.weight(.semibold))
                    Text("Restoring puts the folder, and the links other tools use, back where they were.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            List(store.quarantinedSkills) { q in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.name)
                        Text("Removed \(q.removedAt.formatted(.relative(presentation: .named)))" + (q.topFinding.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Restore") { error = store.restoreSkill(q); Task { await store.loadSkills() } }
                    Button("Delete…", role: .destructive) { store.deleteQuarantined(q) }
                }
            }
            .overlay { if store.quarantinedSkills.isEmpty { ContentUnavailableView("Nothing removed", systemImage: "checkmark.shield") } }
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(12) }
        }
        .frame(width: 560, height: 420)
    }
}
