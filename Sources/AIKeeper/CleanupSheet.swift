import SwiftUI

struct CleanupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let plan: CleanupPlan

    @State private var options: CleanupOptions
    @State private var job: CleanupJob?   // set once started; the job keeps running if this sheet is closed

    init(plan: CleanupPlan) {
        self.plan = plan
        // Artifacts are rebuildable, so skip the Trash by default; whole workspaces go to Trash.
        _options = State(initialValue: CleanupOptions(permanent: plan.mode == .purgeArtifacts))
    }

    private var removing: Bool { plan.mode == .removeWorkspaces }
    private var dangerous: [Entry] { plan.entries.filter { $0.safety == .danger } }
    private var busy: [Entry] { removing ? plan.entries.filter { !store.runningAgents(in: $0).isEmpty } : [] }
    private var agentsHere: [Entry] { removing ? [] : plan.entries.filter { !store.runningAgents(in: $0).isEmpty } }
    private var targets: [Entry] {
        let base = removing && !options.includeDanger ? plan.entries.filter { $0.safety != .danger } : plan.entries
        return base.filter { e in !busy.contains { $0.id == e.id } }
    }
    private func bytes(_ e: Entry) -> Int64 { removing ? (e.size ?? 0) : e.artifactBytes }
    private var total: Int64 { targets.reduce(0) { $0 + bytes($1) } }
    private var conductorLive: [Entry] {
        removing ? targets.filter { $0.sources.contains(.conductor) && $0.conductorState == "ready" } : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job { JobPanel(job: job, onClose: { dismiss() }) }
            else { confirm }
        }
        .padding(24).frame(width: 540)
        .animation(.smooth(duration: 0.2), value: job == nil)
    }

    // MARK: Confirm

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: removing ? "trash.circle.fill" : "wind.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(removing ? .red : .orange)
                VStack(alignment: .leading) {
                    Text(removing ? "Remove \(targets.count) item\(targets.count == 1 ? "" : "s")?" : "Clean build artifacts?")
                        .font(.title2.bold())
                    Text("Frees about \(total.bytesString)").foregroundStyle(.secondary)
                }
            }

            List(targets) { e in
                HStack {
                    VStack(alignment: .leading) {
                        Text(e.name).lineLimit(1)
                        Text(removing ? e.path : e.artifacts.map(\.label).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if removing { let (t, c) = e.statusPill; Pill(text: t, color: c) }
                    Text(bytes(e).bytesString).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(height: min(CGFloat(targets.count) * 44 + 8, 240))
            .listStyle(.bordered)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $options.permanent) {
                    Text("Move to Trash (recoverable)").tag(false)
                    Text("Delete permanently (frees space now)").tag(true)
                }.pickerStyle(.radioGroup).labelsHidden()
                if removing {
                    Toggle("Also delete local branches that are already merged", isOn: $options.deleteMergedBranches)
                    if targets.contains(where: Vault.needsSnapshot) {
                        Toggle("Save a recovery snapshot of unsaved work first (recommended)", isOn: $options.vault)
                    }
                }
                if removing && !dangerous.isEmpty {
                    Toggle(isOn: $options.includeDanger) {
                        Text("Include \(dangerous.count) with uncommitted changes — **that work will be lost**")
                            .foregroundStyle(.red)
                    }
                }
            }

            if !busy.isEmpty {
                Label("\(busy.count) skipped: an agent is running in \(busy.map(\.name).prefix(2).joined(separator: ", ")). Stop it first.",
                      systemImage: "bolt.slash.fill").font(.callout).foregroundStyle(.orange)
            }
            if !agentsHere.isEmpty {
                Label("An agent is running in \(agentsHere.map(\.name).prefix(2).joined(separator: ", ")). A build in progress will fail and has to restart.",
                      systemImage: "bolt.fill").font(.callout).foregroundStyle(.orange)
            }
            if !conductorLive.isEmpty {
                Label("\(conductorLive.count) workspace\(conductorLive.count == 1 ? " is" : "s are") still active in Conductor. Archive in Conductor instead if you want its record cleaned too.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !options.permanent {
                Label("Trash keeps the space used until you empty it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(removing ? "Remove" : "Clean") {
                    job = store.startCleanup(CleanupPlan(mode: plan.mode, entries: targets), options: options)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(removing ? .red : .orange)
                .disabled(targets.isEmpty)
            }
        }
    }
}
