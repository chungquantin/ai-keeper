import SwiftUI

/// Confirm what is in the basket, watch it go, then see what you got back, with a way to undo it.
struct BasketSheet: View {
    @Environment(Store.self) private var store
    @Environment(Basket.self) private var basket
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.Key.reclaimDeleteNow) private var deleteNow = true
    @State private var jobs: [CleanupJob] = []
    @State private var started = Date()
    @State private var freeBefore: Int64 = 0

    var body: some View {
        let items = store.reclaimItems
        VStack(alignment: .leading, spacing: 18) {
            if jobs.isEmpty { confirm(items) } else { BasketProgress(jobs: jobs, started: started, freeBefore: freeBefore, deleteNow: deleteNow) { dismiss() } }
        }
        .padding(28).frame(width: 580)
        .animation(.smooth(duration: 0.2), value: jobs.isEmpty)
    }

    // MARK: Confirm

    private func confirm(_ items: [ReclaimItem]) -> some View {
        let plan = basket.plan(items)
        let total = basket.total(items)
        let picked = items.filter { basket.contains($0) && basket.bytes($0) > 0 }
        let risky = picked.filter { !$0.tier.isSafe }
        let left = items.filter { !basket.contains($0) && !$0.tier.isSafe }
        let busy = (plan.removeSafe + plan.removeRisky).filter { !store.runningAgents(in: $0).isEmpty }
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(total > 0 ? "Reclaim \(total.bytesString)?" : "Nothing selected").font(.bTitle2.bold())
                Text(deleteNow ? "Everything here can be recreated, so it is deleted now and the space comes back at once."
                               : "Everything moves to the Trash. The space comes back when you empty it.")
                    .font(.bCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(picked) { item in
                    HStack(spacing: 10) {
                        Circle().fill(item.tier.color).frame(width: 7, height: 7)
                        (Text(item.title).fontWeight(.medium) + Text(" · \(item.tier.title)").foregroundStyle(.secondary)).font(.bBody).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(basket.bytes(item).bytesString).font(.bBody).monospacedDigit()
                    }.padding(.vertical, 10).overlay(alignment: .top) { Divider() }
                }
            }
            if !risky.isEmpty {
                Label("Includes work that exists nowhere else. We save a snapshot first and move it to the Trash. You can restore it from History for 30 days.", systemImage: "exclamationmark.triangle.fill")
                    .font(.bCallout).foregroundStyle(Brand.reclaimText).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What stays").font(.bCaption2).foregroundStyle(.secondary)
                stays("Your source code and branches on the remote")
                if !left.isEmpty { stays("\(left.reduce(0) { $0 + $1.count }) workspaces and leftovers in Only here, \(left.reduce(0) { $0 + $1.bytes }.bytesString)") }
                stays(busy.isEmpty ? "Anything an agent is running in right now" : "\(busy.count) workspace\(busy.count == 1 ? "" : "s") an agent is running in, skipped")
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                Seg([("Delete now", true), ("Move to Trash", false)], selection: $deleteNow)
                Text(deleteNow ? "Restore from GitHub or Trash is kept in History." : "Trash keeps the space used.").font(.bCaption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(total > 0 ? "Reclaim \(total.bytesString)" : "Reclaim") {
                    started = Date(); freeBefore = store.disk.available
                    jobs = store.reclaim(plan, deleteNow: deleteNow)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.brandProminent).controlSize(.large).disabled(plan.isEmpty)
            }
        }
    }

    private func stays(_ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentColor.good)
            Text(t).font(.bCallout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Progress for the jobs the basket started, then the result.
struct BasketProgress: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    let jobs: [CleanupJob]
    let started: Date
    let freeBefore: Int64
    let deleteNow: Bool
    let close: () -> Void
    @State private var undoing = false
    @State private var undoMessage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let done = jobs.allSatisfy { $0.state == .finished }
            VStack(alignment: .leading, spacing: 18) { if done { result } else { running } }
        }
    }

    private var running: some View {
        let freed = jobs.reduce(Int64(0)) { $0 + $1.status.freed }
        let total = max(jobs.reduce(Int64(0)) { $0 + $1.status.total }, 1)
        let cur = jobs.first { $0.state == .running }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deleteNow ? "Deleting…" : "Moving to Trash…").font(.bTitle2.bold())
                    Text(cur?.status.label.isEmpty == false ? cur!.status.label : "Getting ready").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(Int(min(1, Double(freed) / Double(total)) * 100))%").font(.figure(44)).monospacedDigit()
            }
            PixelMeter(value: min(1, Double(freed) / Double(total)), tint: Brand.accent)
            HStack {
                Text("\(freed.bytesString) of \(total.bytesString)").monospacedDigit()
                Spacer()
                if let s = cur?.status, s.speed > 0 { Text("\(Int64(s.speed).bytesString)/s" + (s.remaining.map { " · about \($0.shortDuration) left" } ?? "")).foregroundStyle(.secondary).monospacedDigit() }
            }.font(.bCallout)
            HStack {
                Button("Stop", role: .destructive) { jobs.forEach { store.cancelJob($0) } }
                Spacer()
                Text("Keeps going in the background.").font(.bCaption).foregroundStyle(.tertiary)
                Button("Run in background") { close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var result: some View {
        let outcomes = jobs.compactMap(\.outcome)
        let freed = outcomes.reduce(Int64(0)) { $0 + $1.freed }
        let failures = outcomes.flatMap(\.failures)
        let stopped = outcomes.contains { $0.cancelled }
        let ok = failures.isEmpty && !stopped
        let back = RestoreLog.all().filter { $0.date >= started && $0.canRestore }
        let after = store.disk.available
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TierChip(symbol: ok ? "checkmark" : "exclamationmark.triangle", tone: ok ? .green : .amber, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deleteNow ? "\(freed.bytesString) freed" : "\(freed.bytesString) moved to Trash").font(.bTitle3)
                    if deleteNow, freeBefore > 0, after > freeBefore { Text("Free space on this Mac: \(freeBefore.bytesString) → \(after.bytesString)").font(.bCaption).foregroundStyle(.secondary) }
                    else if !deleteNow { Text("Empty the Trash to get the space back.").font(.bCaption).foregroundStyle(.secondary) }
                    else if stopped { Text("Stopped early. Whatever was left is still on disk.").font(.bCaption).foregroundStyle(.secondary) }
                }
            }
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(failures.count) could not be removed").font(.bHeadline)
                    ForEach(failures.indices, id: \.self) { i in Text("\(failures[i].name): \(failures[i].error)").font(.bCaption).foregroundStyle(.secondary) }
                }
            }
            if deleteNow {
                Note(text: "Docker's disk image, if you pruned it, shrinks later. Build folders and caches are rebuilt by your next build.")
            }
            if let undoMessage { Text(undoMessage).font(.bCallout).foregroundStyle(.secondary) }
            HStack {
                if !back.isEmpty {
                    Button { undo(back) } label: { Label(undoing ? "Putting back…" : "Undo, put \(back.count) back", systemImage: "arrow.uturn.backward") }.disabled(undoing)
                }
                Button("Open History") { nav.open(.cleanup, .cleaned); close() }
                Spacer()
                Button("Done") { jobs.forEach { store.dismissJob($0) }; close() }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
            }
        }
    }

    private func undo(_ records: [RestoreRecord]) {
        undoing = true
        Task {
            let errors = await Task.detached(priority: .userInitiated) { records.compactMap { RestoreLog.restore($0) } }.value
            undoing = false
            undoMessage = errors.isEmpty ? "Put back \(records.count)." : "Put back \(records.count - errors.count). \(errors.first ?? "")"
            await store.rescan()
        }
    }
}
