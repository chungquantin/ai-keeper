import SwiftUI

/// "Customize metrics": every metric AI Keeper can show, where it comes from, and whether it works today.
struct MetricsCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    private struct Grp: Identifiable { let id = UUID(); let name: String; let sub: String; let items: [(String, Source)] }
    private enum Source { case files, git, system, hook
        var label: String { switch self { case .files: "Session files"; case .git: "Git and GitHub"; case .system: "System"; case .hook: "Needs a hook" } }
        var tone: Tone { switch self { case .files: .blue; case .git: .violet; case .system: .gray; case .hook: .amber } }
    }
    private let groups: [Grp] = [
        Grp(name: "Speed", sub: "How long things take", items: [("Time to first edit", .files), ("Turn time p50 and p95", .files), ("Session length", .files), ("Output speed in tokens a second", .files), ("Time spent thinking", .files), ("Time running tools", .files), ("Time waiting on you", .files), ("Stalls inside a turn", .hook)]),
        Grp(name: "Cost", sub: "What it spends", items: [("Spend by agent and model", .files), ("Cost per session", .files), ("Cost per merged pull request", .git), ("Input, output and cache tokens", .files), ("Budget used today", .files), ("Projected spend this month", .files), ("Cost of abandoned sessions", .files), ("Cost of loops", .files)]),
        Grp(name: "Reliability", sub: "What fails", items: [("Failed tool calls", .files), ("Failed commands by name", .files), ("Retries per task", .files), ("Loops caught", .files), ("Edits you rejected", .files), ("Hook failures", .files), ("MCP timeouts", .files), ("Crashes and forced quits", .hook)]),
        Grp(name: "Context and cache", sub: "How the window is used", items: [("Context used by turn", .files), ("Sessions over 80%", .files), ("Compactions", .files), ("Cache hit rate", .files), ("Money saved by the cache", .files), ("What fills the window", .files), ("Cache breaks and why", .files), ("Skills and instructions loaded", .files)]),
        Grp(name: "Outcomes", sub: "What you get back", items: [("Sessions merged", .git), ("Sessions abandoned", .files), ("Tests passed after the last edit", .files), ("Lines kept after review", .git), ("Time from prompt to merge", .git), ("Reverts within a week", .git), ("Useful turns", .files), ("Review comments per pull request", .git)]),
        Grp(name: "Your habits", sub: "How you work", items: [("Hours you work with agents", .files), ("Prompt length and wording", .files), ("Prompts that name a file", .files), ("Parallel agents at once", .files), ("Permission prompts approved", .files), ("Reply time when an agent waits", .files), ("Sessions you resume", .files), ("Switches between agents", .files)]),
        Grp(name: "Workspaces and disk", sub: "What they leave behind", items: [("Disk used by worktrees", .system), ("Build folders by size", .system), ("Workspaces whose PR merged", .git), ("Space reclaimed over time", .system), ("Branches never pushed", .git), ("Duplicate files merged", .system), ("Docker and OrbStack growth", .system), ("Stale worktrees by age", .git)]),
        Grp(name: "Machine", sub: "What it costs the Mac", items: [("CPU while agents run", .system), ("Memory and swap", .system), ("Battery drained per session", .system), ("Disk I/O during builds", .system), ("Network used by agents", .system), ("Fan and thermal throttling", .system), ("Processes left running", .system), ("Ports left open", .system)]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every metric AI Keeper can show").font(.brand(20, .semibold))
                    Text("64 metrics in 8 groups, all computed on this Mac from files the agents already write, from git, or from the system.").font(.bCallout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) { ForEach([Source.files, .git, .system, .hook], id: \.label) { Tag(text: $0.label, tone: $0.tone) } }
            }.padding(24)
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 4), spacing: 14) {
                    ForEach(groups) { g in
                        Card(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 1) { Text(g.name).font(.bHeadline); Text(g.sub).font(.bCaption).foregroundStyle(.secondary) }.padding(14)
                                ForEach(g.items.indices, id: \.self) { i in
                                    Divider()
                                    HStack(spacing: 6) {
                                        Text(g.items[i].0).font(.bCaption.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 4)
                                        Tag(text: g.items[i].1.label, tone: g.items[i].1.tone)
                                    }.padding(.horizontal, 14).padding(.vertical, 7)
                                }
                            }
                        }
                    }
                }.padding(24)
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.brandProminent).controlSize(.large) }.padding(14)
        }
        .frame(width: 1200, height: 760).background(Brand.background)
    }
}
