import Foundation

enum CleanCommands {
    static var all: [Command] { [remove, clean, leftovers, dedupe, docker] }

    private static let cleanOptions = ["--yes", "--permanent", "--json"]

    /// Picks targets and the reasons some were skipped. Used by `remove`, `clean` and `leftovers clean`.
    private static func select(_ a: Args, selectors: [String], kinds: Set<Kind>, everything: Bool, pool: (Entry) -> Bool,
                               mode: PlanMode, includeDanger: Bool, includeRunning: Bool, entries: [Entry]) -> (targets: [Entry], skipped: [(String, String)])? {
        var chosen: [Entry] = []
        for s in selectors {
            switch Library.resolve(s, in: entries, kinds: kinds) {
            case .failed(let m): Out.fail(m); return nil
            case .found(let e): if !chosen.contains(where: { $0.id == e.id }) { chosen.append(e) }
            }
        }
        if everything { chosen += entries.filter { kinds.contains($0.kind) && pool($0) && !chosen.contains($0) } }
        guard !chosen.isEmpty else {
            Out.fail(everything ? "nothing to do." : "say what to clean: a name or path, or --all.")
            return nil
        }
        let running = Library.agents()
        var targets: [Entry] = [], skipped: [(String, String)] = []
        for e in chosen {
            if e.kind == .repo, mode == .removeWorkspaces { skipped.append((e.name, "a main checkout is never removed (use `keeper clean` for its build folders)")); continue }
            if !e.exists { skipped.append((e.name, "already gone")); continue }
            if mode == .removeWorkspaces, e.safety == .danger, !includeDanger { skipped.append((e.name, "has work that exists nowhere else; add --danger to remove it anyway")); continue }
            if mode == .purgeArtifacts, e.artifacts.isEmpty { continue }
            let agents = Library.agents(in: e, from: running)
            if !agents.isEmpty, !includeRunning { skipped.append((e.name, "\(agents.first!.kind.rawValue) is running in it (pid \(agents.first!.pid))")); continue }
            targets.append(e)
        }
        return (targets, skipped)
    }

    private static func finish(_ a: Args, mode: PlanMode, targets: [Entry], skipped: [(String, String)], options: CleanupOptions, explicit: Bool, all: inout [Entry]) -> Int32 {
        let bytes: (Entry) -> Int64 = { mode == .removeWorkspaces ? ($0.size ?? 0) : $0.artifactBytes }
        let total = targets.reduce(Int64(0)) { $0 + bytes($1) }
        if !a.yes {
            if a.json {
                Out.json(["dry_run": true, "total_bytes": total, "targets": targets.map { ["name": $0.name, "path": $0.path, "bytes": bytes($0)] },
                          "skipped": skipped.map { ["name": $0.0, "reason": $0.1] }] as [String: Any]); return 0
            }
            if targets.isEmpty { for s in skipped { Out.note(Term.yellow("Skipped ") + s.0 + ": " + s.1) }; Out.line("Nothing to do."); return explicit && !skipped.isEmpty ? 1 : 0 }
            let rows = targets.map { e -> [Out.Cell] in
                [Out.Cell(Fmt.size(bytes(e))), Out.Cell(mode == .removeWorkspaces ? Library.statusText(e) : "\(e.artifacts.count) folder\(e.artifacts.count == 1 ? "" : "s")", Term.dim),
                 Out.Cell("\(e.repoName) · \(e.name)")]
            }
            Library.printPlan(title: mode == .removeWorkspaces ? "Would remove" : "Would clean build folders in", rows: rows,
                              headers: ["SIZE", mode == .removeWorkspaces ? "STATUS" : "FOLDERS", "WORKSPACE"], total: total, skipped: skipped, yes: false)
            if mode == .removeWorkspaces {
                Out.note(Term.dim(options.permanent ? "Permanent: files are deleted, not moved to the Trash." : "Files move to the Trash. Unsaved work is saved to the vault first."))
            }
            return 0
        }
        guard !targets.isEmpty else {
            for s in skipped { Out.note(Term.yellow("Skipped ") + s.0 + ": " + s.1) }
            if a.json { Out.json(["freed_bytes": 0, "removed": 0, "skipped": skipped.map { ["name": $0.0, "reason": $0.1] }] as [String: Any]) } else { Out.line("Nothing to do.") }
            return explicit && !skipped.isEmpty ? 1 : 0
        }
        let outcome = Library.execute(mode, targets, options: options, all: &all)
        for s in skipped { Out.note(Term.yellow("Skipped ") + s.0 + ": " + s.1) }
        if a.json {
            Out.json(["freed_bytes": outcome.freed, "removed": outcome.done.count, "failures": outcome.failures.map { ["name": $0.name, "error": $0.error] },
                      "skipped": skipped.map { ["name": $0.0, "reason": $0.1] }] as [String: Any])
        } else {
            let n = outcome.done.count
            Out.line("Freed " + Term.bold(Fmt.size(outcome.freed)) + (mode == .purgeArtifacts ? " of build folders in \(n) workspace\(n == 1 ? "" : "s")." : " by removing \(n) item\(n == 1 ? "" : "s")."))
            for f in outcome.failures { Out.fail("\(f.name): \(f.error)") }
        }
        return outcome.failures.isEmpty ? 0 : 1
    }

    static let remove = Command(
        name: "remove", aliases: ["rm"], group: "Clean up", summary: "Remove workspaces (to the Trash, unsaved work saved first)",
        usage: ["keeper remove <name | repo/name | path>... [--yes]", "keeper remove --all-safe [--yes]", "",
                "  --all-safe      Every workspace judged safe to remove (merged, abandoned or stale, nothing unsaved)",
                "  --yes           Do it. Without this the command only shows what it would remove",
                "  --permanent     Delete for good instead of moving to the Trash",
                "  --no-snapshot   Skip saving unpushed and uncommitted work to the vault",
                "  --keep-branches Keep the local git branches of merged workspaces",
                "  --danger        Also remove workspaces with work that exists nowhere else",
                "  --force         Also remove workspaces an agent is running in"],
        flags: ["all-safe", "permanent", "no-snapshot", "keep-branches", "danger", "force"],
        run: { a in
            guard var entries = Library.requireScan() else { return 1 }
            var o = CleanupOptions()
            o.vault = !a.flag("no-snapshot"); o.permanent = a.flag("permanent"); o.deleteMergedBranches = !a.flag("keep-branches"); o.includeDanger = a.flag("danger")
            guard let p = select(a, selectors: a.positional, kinds: [.workspace, .repo], everything: a.flag("all-safe"),
                                 pool: { $0.verdict == .deprecated && $0.safety == .safe }, mode: .removeWorkspaces,
                                 includeDanger: o.includeDanger, includeRunning: a.flag("force"), entries: entries) else { return 2 }
            return finish(a, mode: .removeWorkspaces, targets: p.targets, skipped: p.skipped, options: o, explicit: !a.positional.isEmpty, all: &entries)
        })

    static let clean = Command(
        name: "clean", group: "Clean up", summary: "Delete build folders (target, node_modules, .venv…) and keep the workspaces",
        usage: ["keeper clean <name | repo/name | path>... [--yes]", "keeper clean --all [--yes]", "",
                "  --all         Every workspace and main checkout with rebuildable folders",
                "  --yes         Do it. Without this the command only shows what it would delete",
                "  --permanent   Delete for good instead of moving to the Trash",
                "  --force       Also clean workspaces an agent is running in"],
        flags: ["all", "permanent", "force"],
        run: { a in
            guard var entries = Library.requireScan() else { return 1 }
            var o = CleanupOptions(); o.permanent = a.flag("permanent"); o.vault = false
            guard let p = select(a, selectors: a.positional, kinds: [.workspace, .repo], everything: a.flag("all"), pool: { $0.artifactBytes > 0 },
                                 mode: .purgeArtifacts, includeDanger: true, includeRunning: a.flag("force"), entries: entries) else { return 2 }
            return finish(a, mode: .purgeArtifacts, targets: p.targets, skipped: p.skipped, options: o, explicit: !a.positional.isEmpty, all: &entries)
        })

    static let leftovers = Command(
        name: "leftovers", group: "Clean up", summary: "Leftovers: chat history of deleted workspaces and tool caches",
        usage: ["keeper leftovers [--json]", "keeper leftovers clean <name>... [--yes]", "keeper leftovers clean --all [--yes]", "",
                "  Session data whose project folder no longer exists, and caches your agent tools can rebuild."],
        flags: ["all", "permanent"],
        run: { a in
            guard var entries = Library.requireScan() else { return 1 }
            let pool = entries.filter { $0.kind == .sessionData || $0.kind == .cache }
            if a.positional.first == "clean" {
                var o = CleanupOptions(); o.permanent = a.flag("permanent"); o.vault = false
                guard let p = select(a, selectors: Array(a.positional.dropFirst()), kinds: [.sessionData, .cache], everything: a.flag("all"), pool: { _ in true },
                                     mode: .removeWorkspaces, includeDanger: true, includeRunning: true, entries: entries) else { return 2 }
                return finish(a, mode: .removeWorkspaces, targets: p.targets, skipped: p.skipped, options: o, explicit: a.positional.count > 1, all: &entries)
            }
            let sorted = pool.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            if a.json { Out.json(sorted.map(Library.dict)); return 0 }
            guard !sorted.isEmpty else { Out.line("No leftovers."); return 0 }
            Out.line(Out.table(["SIZE", "KIND", "NAME", "WHAT IT IS"],
                               sorted.map { [Out.Cell(Fmt.size($0.size ?? 0)), Out.Cell($0.kind == .cache ? "cache" : "history", Term.dim), Out.Cell($0.name), Out.Cell($0.note, Term.dim)] }, right: [0]))
            Out.line(Term.dim("\nTotal \(Fmt.size(sorted.reduce(Int64(0)) { $0 + ($1.size ?? 0) })) · `keeper leftovers clean --all --yes`"))
            return 0
        })

    static let dedupe = Command(
        name: "dedupe", aliases: ["duplicates"], group: "Clean up", summary: "Find identical files in node_modules and friends; replace copies with APFS clones",
        usage: ["keeper dedupe [folder...] [--merge --yes] [--json]", "",
                "  Without folders it uses the node_modules, .venv and Pods folders from the last scan.",
                "  --merge --yes   Replace duplicates with copy-on-write clones. Each file is verified byte for byte first."],
        flags: ["merge"],
        run: { a in
            var roots = a.positional.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
            if roots.isEmpty { roots = Dedup.roots(from: Library.entries().filter { $0.kind == .workspace || $0.kind == .repo }) }
            guard !roots.isEmpty else { Out.fail("no folders to look in. Pass some, or run `keeper scan` first."); return 2 }
            let flag = DedupModel.CancelFlag()
            let report = Dedup.analyze(roots: roots, flag: flag) { phase in
                switch phase {
                case .scanning(let n): Out.status("Scanning… \(n) files")
                case .hashing(let d, let t): Out.status("Comparing \(d)/\(t)")
                default: break
                }
            }
            Out.endStatus()
            let top = report.groups.sorted { $0.reclaim > $1.reclaim }
            let merging = a.flag("merge") && a.yes
            var freed: Int64 = 0, failed = 0
            if merging {
                let m = Dedup.merge(report, flag: flag) { d, t, f in Out.status("Merging \(d)/\(t) · \(Fmt.size(f)) saved") }
                Out.endStatus(); freed = m.freed; failed = m.failed
            }
            if a.json {
                Out.json(["scanned_files": report.scannedFiles, "duplicate_files": report.duplicateFiles, "reclaimable_bytes": report.reclaim, "merged": merging,
                          "freed_bytes": freed, "failed": failed, "top": top.prefix(10).map { ["size_bytes": $0.size, "copies": $0.paths.count, "paths": Array($0.paths.prefix(3))] }] as [String: Any])
                return failed == 0 ? 0 : 1
            }
            Out.line("Scanned \(report.scannedFiles) files: \(report.duplicateFiles) duplicates, \(Term.bold(Fmt.size(report.reclaim))) reclaimable.")
            if !top.isEmpty && !merging {
                Out.line()
                Out.line(Out.table(["SAVES", "COPIES", "FILE"], top.prefix(10).map { [Out.Cell(Fmt.size($0.reclaim)), Out.Cell("\($0.paths.count)", Term.dim), Out.Cell(Fmt.tilde($0.paths[0]))] }, right: [0, 1]))
            }
            if merging { Out.line("Merged. Saved \(Term.bold(Fmt.size(freed)))" + (failed > 0 ? ", \(failed) files skipped (changed or on another volume)." : ".")) }
            else if report.reclaim > 0 { Out.line(Term.dim("\nDry run. Add --merge --yes to replace the copies with clones.")) }
            return failed == 0 ? 0 : 1
        })

    private static let dockerActions: [(id: String, args: [String], detail: String, dangerous: Bool)] = [
        ("builder", ["builder", "prune", "-af"], "build cache (rebuilt on demand)", false),
        ("images", ["image", "prune", "-af"], "unused images (pulled again when needed)", false),
        ("containers", ["container", "prune", "-f"], "stopped containers", false),
        ("volumes", ["volume", "prune", "-af"], "unused volumes (data stored there is deleted for good)", true),
    ]

    static let docker = Command(
        name: "docker", aliases: ["containers"], group: "Clean up", summary: "Docker and OrbStack disk usage, and safe pruning",
        usage: ["keeper docker [--json]", "keeper docker prune <builder|images|containers|volumes|all-safe> [--yes]", "",
                "  all-safe = build cache, unused images and stopped containers. Volumes hold data and must be named explicitly."],
        run: { a in
            if a.positional.first == "prune" {
                guard let what = a.positional.dropFirst().first else { Out.fail("what to prune? builder, images, containers, volumes or all-safe."); return 2 }
                let chosen = what == "all-safe" ? dockerActions.filter { !$0.dangerous } : dockerActions.filter { $0.id == what }
                guard !chosen.isEmpty else { Out.fail("unknown target '\(what)'."); return 2 }
                if !a.yes {
                    for c in chosen { Out.line("Would prune \(c.detail)" + (c.dangerous ? Term.red("  DATA LOSS") : "")) }
                    Out.line(Term.dim("\nDry run. Add --yes to run it.")); return 0
                }
                for c in chosen { Out.status("Pruning \(c.id)…"); let r = DockerCLI.prune(c.args); Out.endStatus(); Out.line(Term.bold(c.id) + "  " + (r.split(separator: "\n").last.map(String.init) ?? "done")) }
                return 0
            }
            let u = DockerCLI.usage()
            if let err = u.error { if a.json { Out.json(["error": err]) } else { Out.fail(err) }; return 1 }
            if a.json { Out.json(u.rows.map { ["type": $0.type, "total": $0.total, "active": $0.active, "size": $0.size, "reclaimable": $0.reclaimable] }); return 0 }
            Out.line(Out.table(["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"], u.rows.map { [Out.Cell($0.type), Out.Cell($0.total, Term.dim), Out.Cell($0.active, Term.dim), Out.Cell($0.size, Term.dim), Out.Cell($0.reclaimable)] }, right: [1, 2, 3]))
            Out.line(Term.dim("\n`keeper docker prune all-safe --yes`"))
            return 0
        })
}
