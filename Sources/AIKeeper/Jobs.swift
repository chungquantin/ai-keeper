import AppKit
import SwiftUI

/// One cleanup, running in the background. Each job is its own observable object, so its 4 Hz progress
/// updates redraw only the views watching it, not the whole app.
@MainActor
final class CleanupJob: ObservableObject, Identifiable {
    enum State { case queued, running, finished }

    let id = UUID()
    let plan: CleanupPlan
    let options: CleanupOptions
    let targets: [Entry]
    let title: String
    let prog = CleanProgress()
    @Published var state: State = .queued
    @Published var status: CleanupStatus
    @Published var outcome: CleanupOutcome?

    init(plan: CleanupPlan, options: CleanupOptions, targets: [Entry]) {
        self.plan = plan
        self.options = options
        self.targets = targets
        let bytes = targets.reduce(Int64(0)) { $0 + (plan.mode == .removeWorkspaces ? ($1.size ?? 0) : $1.artifactBytes) }
        status = CleanupStatus(itemTotal: targets.count, total: bytes)
        if plan.mode == .removeWorkspaces {
            title = targets.count == 1 ? "Remove \(targets[0].name)" : "Remove \(targets.count) items"
        } else {
            title = targets.count == 1 ? "Clean build folders in \(targets[0].name)" : "Clean build folders in \(targets.count) workspaces"
        }
    }

    var verb: String { options.permanent ? "Deleting" : "Moving to Trash" }
}

extension Store {
    var activeJobs: [CleanupJob] { jobs.filter { $0.state != .finished } }

    /// Queue a cleanup and return at once. Jobs run one at a time so they don't fight over the disk.
    @discardableResult
    func startCleanup(_ plan: CleanupPlan, options: CleanupOptions) -> CleanupJob {
        let targets = (plan.mode == .removeWorkspaces
            ? plan.entries.filter { options.includeDanger || $0.safety != .danger }
            : plan.entries).filter { plan.mode == .purgeArtifacts || runningAgents(in: $0).isEmpty }   // never pull a folder from under an agent
        let job = CleanupJob(plan: plan, options: options, targets: targets)
        jobs.append(job)
        pumpJobs()
        return job
    }

    func cancelJob(_ job: CleanupJob) {
        switch job.state {
        case .queued:
            job.outcome = CleanupOutcome(cancelled: true)
            job.state = .finished
        case .running:
            job.prog.cancel()
            job.status.cancelling = true
        case .finished: break
        }
    }

    func dismissJob(_ job: CleanupJob) {
        guard job.state == .finished else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinishedJobs() { jobs.removeAll { $0.state == .finished } }

    private func pumpJobs() {
        guard jobRunner == nil, let next = jobs.first(where: { $0.state == .queued }) else { return }
        jobRunner = Task {
            await runJob(next)
            jobRunner = nil
            pumpJobs()
        }
    }

    private func runJob(_ job: CleanupJob) async {
        let prog = job.prog, plan = job.plan, options = job.options, targets = job.targets
        let bytes: (Entry) -> Int64 = { plan.mode == .removeWorkspaces ? ($0.size ?? 0) : $0.artifactBytes }
        job.state = .running
        job.status.started = .now
        var outcome = CleanupOutcome()
        var removed: [(path: String, bytes: Int64)] = []

        // Poll the background deleter so every view watching this job shows where it is right now.
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                job.status.freed = prog.freed
                job.status.label = prog.label
                job.status.detail = prog.detail
                job.status.cancelling = prog.isCancelled
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        var settled: Int64 = 0
        for (i, e) in targets.enumerated() {
            if prog.isCancelled { break }
            job.status.itemIndex = i + 1
            let result: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
                Result { try plan.mode == .removeWorkspaces
                    ? Cleaner.remove(e, options: options, progress: prog)
                    : Cleaner.purgeArtifacts(e, permanent: options.permanent, progress: prog) }
            }.value
            switch result {
            case .success(let freed) where !prog.isCancelled:
                outcome.freed += freed
                settled += bytes(e)
                prog.raise(to: settled)   // du and unlink disagree slightly; keep the bar honest
                if plan.mode == .removeWorkspaces {
                    entries.removeAll { $0.id == e.id }
                    removed.append((e.path, bytes(e)))
                } else if let idx = entries.firstIndex(where: { $0.id == e.id }) {
                    removed += e.artifacts.map { ($0.path, $0.bytes) }
                    entries[idx].size = max(0, (entries[idx].size ?? 0) - freed)
                    entries[idx].artifacts = []
                }
            case .success:
                outcome.cancelled = true
                outcome.freed += prog.freed - outcome.freed
                let fresh = await Task.detached { Enricher.enrich(e) }.value   // numbers are stale after a partial delete
                replaceEntry(fresh)
            case .failure(let err):
                outcome.failures.append((e.name, err.localizedDescription))
                settled += bytes(e)
            }
        }
        if prog.isCancelled { outcome.cancelled = true }
        poller.cancel()

        job.status.freed = prog.freed
        job.outcome = outcome
        job.state = .finished
        forgetFromMap(removed.map(\.path))
        for r in removed { analyzer.forget(path: r.path, bytes: r.bytes) }
        mapStale = true   // sizes changed; the user decides when to re-measure
        refreshDisk()
        persistEntries()
        if !NSApp.isActive {
            Notifier.send(outcome.cancelled ? "Cleanup stopped" : "Cleanup finished", "\(outcome.freed.bytesString) freed · \(job.title)", id: "job.\(job.id)")
        }
    }
}

// MARK: - Panel shown in the cleanup sheet

/// The running/done view for one job. Closing it never stops the job.
struct JobPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var job: CleanupJob
    let onClose: () -> Void

    var body: some View {
        switch job.state {
        case .queued: queued
        case .running: running
        case .finished: finished(job.outcome ?? CleanupOutcome())
        }
    }

    private var queued: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Waiting in line").font(.title2.bold())
            Text("Another cleanup is running. This one starts when it finishes.").foregroundStyle(.secondary)
            HStack {
                Button("Cancel this cleanup", role: .destructive) { store.cancelJob(job); onClose() }
                Spacer()
                Button("Close") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var running: some View {
        let c = job.status
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.cancelling ? "Stopping…" : "\(job.verb)…").font(.title2.bold())
                    Text(c.label.isEmpty ? "Getting ready" : c.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(Int(c.fraction * 100))%").font(.figure(44)).monospacedDigit().contentTransition(.numericText())
            }
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: c.fraction).progressViewStyle(.linear).tint(Brand.accent)
                HStack {
                    Text("\(c.freed.bytesString) of \(c.total.bytesString)").monospacedDigit()
                    Spacer()
                    if c.speed > 0 {
                        Text("\(Int64(c.speed).bytesString)/s" + (c.remaining.map { " · about \($0.shortDuration) left" } ?? "")).monospacedDigit().foregroundStyle(.secondary)
                    } else { Text("Measuring speed…").foregroundStyle(.secondary) }
                }.font(.callout)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(c.detail.isEmpty ? "Reading folder…" : c.detail, systemImage: "folder")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Text("Item \(c.itemIndex) of \(c.itemTotal) · \(c.elapsed.shortDuration) elapsed").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            HStack {
                Button("Stop", role: .destructive) { store.cancelJob(job) }.disabled(c.cancelling)
                Spacer()
                Text("Keeps going in the background.").font(.caption).foregroundStyle(.tertiary)
                Button("Run in background") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finished(_ o: CleanupOutcome) -> some View {
        let ok = o.failures.isEmpty && !o.cancelled
        return VStack(spacing: 14) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").font(.system(size: 54)).foregroundStyle(ok ? Brand.accent : .orange)
            Text("\(o.freed.bytesString) freed").font(.figure(40))
            if o.cancelled { Text("Stopped early. Whatever was left is still on disk.").foregroundStyle(.secondary) }
            if !job.options.permanent { Text("Moved to Trash. Empty it to get the space back.").foregroundStyle(.secondary) }
            if !o.failures.isEmpty {
                VStack(alignment: .leading) {
                    Text("\(o.failures.count) failed").font(.headline)
                    ForEach(o.failures.indices, id: \.self) { i in Text("\(o.failures[i].name): \(o.failures[i].error)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                if !job.options.permanent { Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) } }
                Button("Done") { store.dismissJob(job); onClose() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Activity (sidebar)

/// Always-visible summary of background cleanups, with a popover for details.
struct ActivityBar: View {
    @EnvironmentObject var store: Store
    @State private var open = false

    var body: some View {
        if !store.jobs.isEmpty {
            Button { open.toggle() } label: { ActivitySummary(jobs: store.jobs).padding(.horizontal, 16).padding(.vertical, 9) }
                .buttonStyle(HoverRowStyle())
                .overlay(alignment: .top) { Divider() }
                .popover(isPresented: $open, arrowEdge: .trailing) { ActivityList().environmentObject(store) }
                .help("Background cleanups")
        }
    }
}

private struct ActivitySummary: View {
    let jobs: [CleanupJob]
    var body: some View {
        if let running = jobs.first(where: { $0.state == .running }) {
            RunningLine(job: running, queued: jobs.filter { $0.state == .queued }.count)
        } else if jobs.contains(where: { $0.state == .queued }) {
            Label("Cleanup waiting", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else {
            FinishedLine(jobs: jobs)
        }
    }
}

private struct RunningLine: View {
    @ObservedObject var job: CleanupJob
    let queued: Int
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: job.status.fraction).progressViewStyle(.circular).controlSize(.small)
            Text("\(job.status.cancelling ? "Stopping" : "Cleaning") · \(Int(job.status.fraction * 100))%" + (queued > 0 ? " · \(queued) waiting" : ""))
                .font(.caption).monospacedDigit()
            Spacer()
            Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FinishedLine: View {
    let jobs: [CleanupJob]
    var body: some View {
        let freed = jobs.reduce(Int64(0)) { $0 + ($1.outcome?.freed ?? 0) }
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
            Text("\(freed.bytesString) freed").font(.caption).monospacedDigit()
            Spacer()
            Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityList: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cleanups").font(.headline)
                Spacer()
                if store.jobs.contains(where: { $0.state == .finished }) { Button("Clear finished") { store.clearFinishedJobs() }.controlSize(.small) }
            }.padding(14)
            Divider()
            ForEach(store.jobs) { job in
                JobRow(job: job)
                if job.id != store.jobs.last?.id { Divider() }
            }
        }.frame(width: 340)
    }
}

private struct JobRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject var job: CleanupJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title).fontWeight(.medium).lineLimit(1)
            switch job.state {
            case .queued:
                HStack { Text("Waiting").foregroundStyle(.secondary); Spacer(); Button("Cancel") { store.cancelJob(job) }.controlSize(.small) }.font(.callout)
            case .running:
                ProgressView(value: job.status.fraction).tint(Brand.accent)
                HStack {
                    Text("\(job.status.freed.bytesString) of \(job.status.total.bytesString)").monospacedDigit()
                    if let r = job.status.remaining { Text("· \(r.shortDuration) left").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Stop") { store.cancelJob(job) }.controlSize(.small).disabled(job.status.cancelling)
                }.font(.callout)
                if !job.status.detail.isEmpty { Text(job.status.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
            case .finished:
                let o = job.outcome ?? CleanupOutcome()
                HStack {
                    Image(systemName: o.failures.isEmpty && !o.cancelled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(o.failures.isEmpty && !o.cancelled ? Brand.accent : .orange)
                    Text("\(o.freed.bytesString) freed" + (o.cancelled ? " · stopped" : o.failures.isEmpty ? "" : " · \(o.failures.count) failed")).font(.callout)
                    Spacer()
                    Button("Dismiss") { store.dismissJob(job) }.controlSize(.small)
                }
            }
        }.padding(14)
    }
}

/// One line for the menu-bar menu.
struct JobMenuLine: View {
    @ObservedObject var job: CleanupJob
    var body: some View {
        Label("Cleaning · \(Int(job.status.fraction * 100))%", systemImage: "wind").foregroundStyle(.orange)
    }
}

// MARK: - Quit guard

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting mid-delete leaves a half-removed folder, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Store.current else { return .terminateNow }
        let active = MainActor.assumeIsolated { store.activeJobs }
        guard !active.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A cleanup is still running"
        alert.informativeText = "Quitting now stops it partway. Anything already removed stays removed."
        alert.addButton(withTitle: "Keep cleaning")
        alert.addButton(withTitle: "Quit anyway")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        MainActor.assumeIsolated { active.forEach { $0.prog.cancel() } }
        return .terminateNow
    }
}
