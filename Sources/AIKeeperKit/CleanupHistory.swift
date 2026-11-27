import SwiftUI

// Cleanup › History: what you cleared, and how to put it back.

struct CleanupHistory: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    @State private var records: [RestoreRecord] = RestoreLog.all()
    @State private var archives: [URL] = Archiver.list()
    @State private var busy: String?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack { Seg([("Cleaned", HistoryMode.cleaned), ("Saved snapshots", HistoryMode.removed)], selection: $nav.historyMode); Spacer() }
                .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 2)
            if nav.historyMode == .removed { VaultView() } else { cleaned }
        }
    }

    private var cleaned: some View {
        Page {
            AdaptiveRow(spacing: 16, minChild: 380) {
                recent.frame(maxWidth: .infinity)
                ReclaimHistory().frame(width: 360)
            }
            if !archives.isEmpty { archiveCard }
            if let message { Text(message).font(.bCaption).foregroundStyle(.secondary) }
        }
    }

    private var recent: some View {
        let list = Array(records.sorted { $0.date > $1.date }.prefix(40))
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Recently removed", note: list.isEmpty ? nil : "\(list.count)").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                if list.isEmpty {
                    Text("Nothing yet. When you remove a workspace, it appears here with a way to bring it back.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 18)
                }
                ForEach(list) { r in
                    HStack(spacing: 12) {
                        TierChip(symbol: r.trash != nil ? "trash" : "arrow.triangle.branch", tone: r.trash != nil ? .gray : .violet, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.bBody.weight(.medium)).lineLimit(1)
                            Text(how(r)).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.bytes.bytesString).font(.bBody).monospacedDigit()
                        if r.restored { Tag(text: "Restored", tone: .green) }
                        else if r.canRestore { Button(busy == r.id ? "Restoring…" : "Restore") { restore(r) }.controlSize(.small).disabled(busy != nil) }
                        else { Tag(text: "Gone") }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
                }
            }
        }
    }

    private func how(_ r: RestoreRecord) -> String {
        let when = r.date.formatted(.relative(presentation: .named))
        if r.trash != nil { return "\(when) · in the Trash" }
        if r.repo != nil, let b = r.branch { return "\(when) · recreate from \(b)" }
        return "\(when) · cannot be restored"
    }

    private var archiveCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Archived transcripts", note: "In Keeper's folder").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                ForEach(archives, id: \.self) { u in
                    HStack(spacing: 12) {
                        TierChip(symbol: "doc.zipper", tone: .gray, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.lastPathComponent).font(.bBody.weight(.medium))
                            Text(((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }).map { Int64($0).bytesString } ?? "").font(.bCaption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.controlSize(.small)
                        Button(busy == u.path ? "Unpacking…" : "Unpack") { unpack(u) }.controlSize(.small).disabled(busy != nil)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
                }
            }
        }
    }

    private func restore(_ r: RestoreRecord) {
        busy = r.id
        Task {
            let err = await Task.detached(priority: .userInitiated) { RestoreLog.restore(r) }.value
            busy = nil
            records = RestoreLog.all()
            message = err ?? "Restored \(r.name)."
            if err == nil { await store.rescan() }
        }
    }

    private func unpack(_ u: URL) {
        busy = u.path
        Task {
            let err = await Task.detached(priority: .userInitiated) { Archiver.restore(u) }.value
            busy = nil
            message = err ?? "Unpacked \(u.lastPathComponent) back to where it came from."
            if err == nil { store.loadTraces(); await store.sources.measure() }
        }
    }
}
