import Foundation

enum SkillLibrary {
    /// Main checkouts from the last scan: where project skills can live.
    static func projects() -> [String] { Library.entries().filter { $0.kind == .repo && $0.exists }.map(\.path) }
    static func skills() -> [SkillInfo] { SkillCatalog.discover(projects: projects()) }

    static func verdict(_ s: SkillInfo, _ cache: [String: SkillScan]) -> SkillVerdict { SkillScanner.current(s, in: cache)?.verdict ?? .unscanned }

    /// By real path, name, or a unique prefix of the name. The same name can exist in several plugin versions, so ambiguity is reported.
    static func resolve(_ sel: String, in list: [SkillInfo]) -> (skill: SkillInfo?, error: String?) {
        let path = URL(fileURLWithPath: (sel as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        if let s = list.first(where: { $0.realPath == path }) { return (s, nil) }
        let q = sel.lowercased()
        var hits = list.filter { $0.name.lowercased() == q }
        if hits.isEmpty { hits = list.filter { $0.name.lowercased().hasPrefix(q) } }
        if hits.count == 1 { return (hits[0], nil) }
        if hits.isEmpty { return (nil, "no skill matches '\(sel)'. Try `keeper skills`.") }
        let lines = hits.prefix(6).map { "  \($0.name)  \(Fmt.tilde($0.realPath))" }.joined(separator: "\n")
        return (nil, "'\(sel)' matches \(hits.count) skills; pass the path:\n\(lines)")
    }

    /// Riskiest first, then what has not been scanned, then the ones that look safe; by name inside each.
    static func sortKey(_ v: SkillVerdict) -> Int { [2, 1, 0, 3][v.rawValue] }

    static func style(_ v: SkillVerdict) -> (String) -> String { [Term.blue, Term.yellow, Term.red, Term.dim][v.rawValue] }

    static func dict(_ s: SkillInfo, scan: SkillScan?, issues: Bool) -> [String: Any] {
        var o: [String: Any] = ["name": s.name, "description": s.description, "tools": s.tools, "scope": s.scope.rawValue, "path": s.locations.first ?? s.realPath,
                                "real_path": s.realPath, "files": s.files, "bytes": s.bytes, "has_scripts": s.hasScripts, "modified": Fmt.iso(s.modified) as Any]
        if let p = s.plugin { o["plugin"] = p }
        if let v = s.pluginVersion { o["plugin_version"] = v }
        if let c = scan {
            var r: [String: Any] = ["verdict": c.verdict.key, "recommendation": c.recommendation, "score": c.score, "severity": c.severity, "issue_count": c.issues.count,
                                    "scanned_at": Fmt.iso(c.scannedAt) as Any, "scanner_version": c.scannerVersion, "complete": c.complete]
            if issues {
                r["issues"] = c.issues.map { ["rule": $0.rule, "category": $0.category, "severity": $0.severity, "confidence": $0.confidence, "file": $0.file, "line": $0.line,
                                              "finding": $0.finding, "explanation": $0.explanation, "remediation": $0.remediation, "snippet": $0.snippet as Any] as [String: Any] }
            }
            o["scan"] = r
        } else { o["scan"] = NSNull() }
        return o
    }
}

enum SkillCommands {
    static var all: [Command] { [skills] }

    private static func scannerHelp() {
        Out.note("""
        SkillSpector, NVIDIA's skill scanner, is not installed.
          Install it:  keeper skills scanner install --yes
          or yourself: \(SkillScanner.installCommand)
        """)
    }

    static let skills = Command(
        name: "skills", aliases: ["skill"], group: "Skills", summary: "Every installed agent skill, and scan them with NVIDIA SkillSpector",
        usage: ["keeper skills [--tool NAME] [--scope user|plugin|project] [--risk safe|caution|danger|unscanned] [--json]",
                "keeper skills show <name | path> [--json]", "keeper skills scan [<name | path>...] [--all] [--rescan] [--json]",
                "keeper skills scanner [install --yes]", "",
                "  Lists the skills your agents can load: Claude Code, plugins, the shared ~/.agents folder, Codex, Pi, Gemini CLI,",
                "  OpenCode, Cursor, Goose and project skills. Skills several tools link to appear once.", "",
                "  scan      Runs SkillSpector (static analysis, nothing is sent to a language model). Results are cached until a skill changes.",
                "            Exits 1 if any skill is rated do-not-install or a scan failed, so it can gate a script.",
                "  --all     Scan every skill (unchanged ones reuse their last result)    --rescan  Scan again even if unchanged",
                "  scanner   Shows the scanner, or installs the reviewed release (\(SkillScanner.pinnedRef)) with uv. Needs --yes.", "",
                "  Privacy: SkillSpector checks the dependencies a skill lists against api.osv.dev, so package names and versions are sent there.",
                "  Skill text stays on your Mac."],
        valueOptions: ["tool", "scope", "risk"],
        flags: ["all", "rescan"],
        run: { a in
            let list = SkillLibrary.skills()
            var cache = SkillScanner.loadCache()
            switch a.positional.first {
            case "scanner": return scanner(a)
            case "show":
                guard let sel = a.positional.dropFirst().first else { Out.fail("which skill? `keeper skills show <name>`"); return 2 }
                let r = SkillLibrary.resolve(sel, in: list)
                guard let s = r.skill else { Out.fail(r.error ?? "not found"); return 1 }
                return show(s, SkillScanner.current(s, in: cache), json: a.json)
            case "scan": return scan(a, list: list, cache: &cache)
            case nil: break
            default: Out.fail("unknown skills command '\(a.positional[0])'. See `keeper help skills`."); return 2
            }

            var rows = list
            if let t = a.value("tool")?.lowercased() { rows = rows.filter { $0.tools.contains { $0.lowercased().replacingOccurrences(of: " ", with: "-") == t || $0.lowercased() == t } } }
            if let sc = a.value("scope") { rows = rows.filter { $0.scope.rawValue == sc } }
            if let rk = a.value("risk") { rows = rows.filter { SkillLibrary.verdict($0, cache).key == rk } }
            if a.json { Out.json(rows.map { SkillLibrary.dict($0, scan: SkillScanner.current($0, in: cache), issues: false) }); return 0 }
            guard !rows.isEmpty else { Out.line(list.isEmpty ? "No skills found. Skills live in folders like ~/.claude/skills and ~/.agents/skills." : "No skills match."); return 0 }
            let table = rows.sorted { (SkillLibrary.sortKey(SkillLibrary.verdict($0, cache)), $0.name.lowercased()) < (SkillLibrary.sortKey(SkillLibrary.verdict($1, cache)), $1.name.lowercased()) }.map { s -> [Out.Cell] in
                let v = SkillLibrary.verdict(s, cache)
                let c = SkillScanner.current(s, in: cache)
                return [Out.Cell(v.label, SkillLibrary.style(v)), Out.Cell(c.map { "\($0.score)" } ?? "", Term.dim), Out.Cell(s.name),
                        Out.Cell(s.tools.joined(separator: ", ") + (s.scope == .plugin ? " · plugin" : ""), Term.dim),
                        Out.Cell(s.hasScripts ? "scripts" : "", Term.yellow), Out.Cell(s.description, Term.dim)]
            }
            Out.line(Out.table(["RISK", "SCORE", "NAME", "WHERE", "", "WHAT IT DOES"], table, right: [1]))
            let scanned = rows.filter { SkillLibrary.verdict($0, cache) != .unscanned }.count
            let bad = rows.filter { SkillLibrary.verdict($0, cache) >= .caution && SkillLibrary.verdict($0, cache) != .unscanned }.count
            Out.line(Term.dim("\n\(rows.count) skills · \(scanned) scanned" + (bad > 0 ? " · \(bad) worth a look" : "") + (scanned < rows.count ? " · `keeper skills scan --all`" : "")))
            return 0
        })

    // MARK: show

    private static func show(_ s: SkillInfo, _ scan: SkillScan?, json: Bool) -> Int32 {
        if json { Out.json(SkillLibrary.dict(s, scan: scan, issues: true)); return 0 }
        Out.line(Term.bold(s.name) + Term.dim("  " + s.tools.joined(separator: ", ") + (s.plugin.map { " · plugin \($0)" + (s.pluginVersion.map { " \($0)" } ?? "") } ?? "")))
        if !s.description.isEmpty { Out.line(s.description) }
        Out.line(Term.dim(Fmt.tilde(s.realPath) + "  ·  \(s.files) files, \(Fmt.size(s.bytes))  ·  changed \(Fmt.ago(s.modified))"))
        if s.locations.count > 1 || s.locations.first != s.realPath { for l in s.locations { Out.line(Term.dim("  listed at " + Fmt.tilde(l))) } }
        if s.hasScripts { Out.line(Term.yellow("Contains scripts") + Term.dim("  (code your agent may run)")) }
        Out.line()
        guard let c = scan else { Out.line(Term.dim("Not scanned yet. `keeper skills scan \(s.name)`")); return 0 }
        let v = c.verdict
        Out.line(SkillLibrary.style(v)(Term.bold(v.label)) + Term.dim("   score \(c.score)/100 · \(c.severity.lowercased()) · SkillSpector \(c.scannerVersion) · \(Fmt.ago(c.scannedAt))"))
        if !c.complete { Out.line(Term.yellow("The scan could not inspect everything, so a clean result is not a guarantee.")) }
        if c.issues.isEmpty { Out.line("No findings."); return 0 }
        Out.line()
        for i in c.issues.prefix(25) {
            let sev: (String) -> String = i.rank >= 4 ? Term.red : i.rank == 3 ? Term.red : i.rank == 2 ? Term.yellow : Term.dim
            Out.line(sev(Term.bold(i.severity)) + "  " + Term.bold(i.finding.isEmpty ? i.category : i.finding) + Term.dim("  \(i.rule) · \(i.category) · confidence \(Int(i.confidence * 100))%"))
            Out.line(Term.dim("  \(i.file)" + (i.line > 0 ? ":\(i.line)" : "")))
            if !i.explanation.isEmpty { Out.line("  " + i.explanation) }
            if let code = i.snippet, !code.isEmpty { for l in code.split(separator: "\n", omittingEmptySubsequences: false).prefix(6) { Out.line(Term.dim("  │ ") + Ansi.fit(String(l), Term.width - 6)) } }
            if !i.remediation.isEmpty { Out.line(Term.dim("  Fix: " + i.remediation)) }
            Out.line()
        }
        if c.issues.count > 25 { Out.line(Term.dim("…and \(c.issues.count - 25) more (use --json for all)")) }
        Out.line(Term.dim("Findings are heuristics: read the lines they point at before deciding."))
        return 0
    }

    // MARK: scan

    private static func scan(_ a: Args, list: [SkillInfo], cache: inout [String: SkillScan]) -> Int32 {
        guard let binary = SkillScanner.locate() else { scannerHelp(); return 1 }
        var targets: [SkillInfo] = []
        for sel in a.positional.dropFirst() {
            let r = SkillLibrary.resolve(sel, in: list)
            guard let s = r.skill else { Out.fail(r.error ?? "not found"); return 2 }
            if !targets.contains(s) { targets.append(s) }
        }
        if a.flag("all") { targets += list.filter { s in !targets.contains(s) } }
        guard !targets.isEmpty else { Out.fail("which skills? Name some, or use --all."); return 2 }
        let rescan = a.flag("rescan")
        let todo = targets.filter { rescan || SkillScanner.current($0, in: cache) == nil }
        Out.note(Term.dim("Scanning with \(Fmt.tilde(binary)): \(todo.count) of \(targets.count) skills (the rest are unchanged since their last scan)."))
        var failures: [(String, String)] = []
        let lock = NSLock()
        var snapshot = cache
        if !todo.isEmpty {
            SkillScanner.scanAll(todo, binary: binary) { s, result, n in
                lock.lock(); defer { lock.unlock() }
                switch result {
                case .success(let c): snapshot[s.realPath] = c; SkillScanner.saveCache(snapshot)
                case .failure(let e): failures.append((s.name, e.localizedDescription))
                }
                Out.status("Scanned \(n)/\(todo.count)  \(s.name)")
            }
            Out.endStatus()
        }
        cache = snapshot
        let results = targets.map { ($0, SkillScanner.current($0, in: cache)) }
        if a.json {
            Out.json(["skills": results.map { SkillLibrary.dict($0.0, scan: $0.1, issues: true) }, "failures": failures.map { ["skill": $0.0, "error": $0.1] }] as [String: Any])
        } else {
            let order = results.sorted { (SkillLibrary.sortKey($0.1?.verdict ?? .unscanned), $0.0.name.lowercased()) < (SkillLibrary.sortKey($1.1?.verdict ?? .unscanned), $1.0.name.lowercased()) }
            let rows = order.map { s, c -> [Out.Cell] in
                let v = c?.verdict ?? .unscanned
                return [Out.Cell(v.label, SkillLibrary.style(v)), Out.Cell(c.map { "\($0.score)" } ?? "", Term.dim), Out.Cell(c.map { "\($0.issues.count)" } ?? "", Term.dim), Out.Cell(s.name),
                        Out.Cell(c?.issues.first.map { "\($0.severity.lowercased()): \($0.finding.isEmpty ? $0.category : $0.finding)" } ?? "", Term.dim)]
            }
            Out.line(Out.table(["RISK", "SCORE", "FINDINGS", "NAME", "TOP FINDING"], rows, right: [1, 2]))
            for f in failures { Out.fail("\(f.0): \(f.1)") }
            let danger = results.filter { $0.1?.verdict == .danger }.count, caution = results.filter { $0.1?.verdict == .caution }.count
            Out.line(Term.dim("\n\(results.count - danger - caution - failures.count) look safe · \(caution) to review · \(danger) do not install" + (failures.isEmpty ? "" : " · \(failures.count) failed")))
            Out.line(Term.dim("`keeper skills show <name>` explains each finding. Findings are heuristics, not verdicts."))
        }
        return results.contains { $0.1?.verdict == .danger } || !failures.isEmpty ? 1 : 0
    }

    // MARK: scanner

    private static func scanner(_ a: Args) -> Int32 {
        let path = SkillScanner.locate()
        if a.positional.dropFirst().first == "install" {
            if let p = path { Out.line("SkillSpector is already installed at \(Fmt.tilde(p))."); return 0 }
            Out.line("This installs NVIDIA's SkillSpector (\(SkillScanner.projectURL)) at the reviewed release \(SkillScanner.pinnedRef):")
            Out.line("  " + Term.bold(SkillScanner.installCommand))
            Out.line(Term.dim("It downloads that release and its Python dependencies (and Python 3.12 if you don't have it) from the internet. AI Keeper doesn't bundle it."))
            guard a.yes else { Out.line(Term.dim("\nDry run. Add --yes to install.")); return 0 }
            Out.status("Installing SkillSpector… this can take a minute or two")
            let r = SkillScanner.install()
            Out.endStatus()
            if r.ok { Out.line(r.message) } else { Out.fail(r.message) }
            return r.ok ? 0 : 1
        }
        if a.json { Out.json(["installed": path != nil, "path": path as Any, "pinned_release": SkillScanner.pinnedRef, "install_command": SkillScanner.installCommand, "project": SkillScanner.projectURL] as [String: Any]); return 0 }
        if let p = path { Out.line("SkillSpector  " + Term.blue("installed") + Term.dim("  \(Fmt.tilde(p))")) }
        else { Out.line("SkillSpector  " + Term.yellow("not installed")); Out.line(Term.dim("  keeper skills scanner install --yes")) }
        Out.line(Term.dim("NVIDIA SkillSpector · Apache-2.0 · \(SkillScanner.projectURL) · AI Keeper installs release \(SkillScanner.pinnedRef)"))
        Out.line(Term.dim("Scans are static (--no-llm). Dependency names and versions are checked against api.osv.dev."))
        return 0
    }
}
