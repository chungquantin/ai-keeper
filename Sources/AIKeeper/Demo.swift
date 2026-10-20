import Foundation

/// Demo mode (AIKEEPER_DEMO=1): the app shows invented but realistic data instead of scanning this Mac.
/// Used to take screenshots for the website without exposing real repositories, paths or spend.
/// It is isolated: caches go to a temporary folder and no setting is written.
enum Demo {
    static var enabled: Bool { ProcessInfo.processInfo.environment["AIKEEPER_DEMO"] == "1" }
    static let user = "/Users/alex"
}

extension Store {
    func loadDemo() {
        let now = Date()
        func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func gb(_ v: Double) -> Int64 { Int64(v * 1_000_000_000) }

        enabledTools = ["claude", "codex", "conductor", "superset", "pi"]
        disk = DiskInfo(total: gb(994.6), available: gb(612.4), purgeable: gb(3.1))
        lastScan = now.addingTimeInterval(-240)
        mapDate = now.addingTimeInterval(-3 * 3600)
        phase = .done

        // MARK: Workspaces

        func pathFor(_ tool: Source, repo: String, name: String) -> String {
            switch tool {
            case .conductor: "\(Demo.user)/conductor/workspaces/\(repo)/\(name)"
            case .codex: "\(Demo.user)/.codex/worktrees/\(String(name.hashValue, radix: 16).suffix(4))/\(repo)"
            case .superset: "\(Demo.user)/.superset/worktrees/\(repo)/\(name)"
            default: "\(Demo.user)/Developer/\(repo)/.claude/worktrees/\(name)"
            }
        }

        func workspace(_ name: String, repo: String, tool: Source, size: Double, artifacts: [(String, Double)],
                       dirty: Int = 0, unpushed: Int = 0, ahead: Int = 0, behind: Int = 0, merged: Bool = false,
                       pr: PRInfo? = nil, hours: Double, subject: String, conductor: String? = nil) -> Entry {
            let path = pathFor(tool, repo: repo, name: name)
            var e = Entry(id: "ws:" + path, kind: .workspace, name: name, path: path, repoPath: "\(Demo.user)/Developer/\(repo)",
                          repoName: repo, branch: tool == .claude ? "claude/\(name)" : name, sources: [tool, .git])
            e.conductorState = conductor
            e.lastActivity = ago(hours: hours)
            e.size = gb(size)
            e.artifacts = artifacts.map { Artifact(path: path + "/" + $0.0, bytes: gb($0.1)) }
            e.git = GitInfo(dirtyCount: dirty, ahead: unpushed, hasUpstream: unpushed == 0, merged: merged, defaultBranch: "main",
                            lastCommit: ago(hours: hours), unpushed: unpushed, aheadOfBase: ahead, behindBase: behind, lastSubject: subject)
            e.pr = pr
            e.measured = true
            Classifier.classify(&e, staleDays: 14)
            return e
        }
        func pr(_ n: Int, _ state: String, _ title: String, draft: Bool = false, review: String? = nil, checks: String? = nil, doneHoursAgo: Double? = nil) -> PRInfo {
            PRInfo(number: n, state: state, url: "https://github.com/acme/app/pull/\(n)", title: title, isDraft: draft, review: review, checks: checks,
                   mergedAt: state == "MERGED" ? ago(hours: doneHoursAgo ?? 1) : nil, closedAt: state == "CLOSED" ? ago(hours: doneHoursAgo ?? 30) : nil)
        }

        var list: [Entry] = [
            workspace("feat-search-index", repo: "api-server", tool: .claude, size: 8.6, artifacts: [("target", 7.9), ("node_modules", 0.4)], ahead: 4,
                      pr: pr(412, "MERGED", "Add full-text search index for orders", doneHoursAgo: 1), hours: 1.5, subject: "Index orders by customer and status"),
            workspace("fix-billing-retry", repo: "api-server", tool: .claude, size: 6.2, artifacts: [("target", 5.6)], ahead: 3,
                      pr: pr(418, "OPEN", "Retry failed billing webhooks with backoff", review: "APPROVED", checks: "pass"), hours: 0.3, subject: "Add exponential backoff to webhook retries"),
            workspace("refactor-auth", repo: "api-server", tool: .conductor, size: 11.4, artifacts: [("target", 10.9)], ahead: 6,
                      pr: pr(405, "MERGED", "Move auth middleware to session tokens", doneHoursAgo: 71), hours: 70, subject: "Replace JWT parsing with session lookup", conductor: "ready"),
            workspace("perf-cache-layer", repo: "api-server", tool: .codex, size: 4.7, artifacts: [("target", 4.2)], ahead: 2, hours: 9, subject: "Cache hot product queries for 30 seconds"),
            workspace("spike-queue", repo: "web-app", tool: .codex, size: 2.1, artifacts: [("node_modules", 1.8)], dirty: 14, ahead: 1, hours: 26, subject: "Try a durable queue for exports"),
            workspace("chore-deps-update", repo: "web-app", tool: .claude, size: 1.4, artifacts: [("node_modules", 1.3)], ahead: 2,
                      pr: pr(431, "CLOSED", "Bump frontend dependencies", doneHoursAgo: 52), hours: 52, subject: "Update React and Vite"),
            workspace("experiment-graphql", repo: "web-app", tool: .conductor, size: 2.9, artifacts: [("node_modules", 2.4)], merged: true, hours: 24 * 31,
                      subject: "Prototype a GraphQL gateway", conductor: "archived"),
            workspace("mobile-onboarding", repo: "mobile-app", tool: .superset, size: 3.3, artifacts: [("Pods", 2.6)], ahead: 5,
                      pr: pr(77, "OPEN", "Redesign the onboarding flow", draft: true, checks: "pending"), hours: 2, subject: "Add the permissions step"),
            workspace("scratch-rename", repo: "docs-site", tool: .claude, size: 0.18, artifacts: [], hours: 24 * 9, subject: "Initial commit"),
            workspace("docs-search-polish", repo: "docs-site", tool: .claude, size: 0.9, artifacts: [("node_modules", 0.7)], ahead: 1,
                      pr: pr(58, "MERGED", "Improve docs search ranking", doneHoursAgo: 8), hours: 8, subject: "Boost title matches"),
            workspace("fix-pagination-bug", repo: "web-app", tool: .claude, size: 1.1, artifacts: [("node_modules", 0.9)], ahead: 1,
                      pr: pr(437, "MERGED", "Fix off-by-one in the orders pager", doneHoursAgo: 5), hours: 5, subject: "Clamp the last page"),
            workspace("feat-export-csv", repo: "web-app", tool: .codex, size: 1.8, artifacts: [("node_modules", 1.5)], ahead: 3,
                      pr: pr(440, "OPEN", "Export orders as CSV", review: "CHANGES_REQUESTED", checks: "fail"), hours: 3, subject: "Stream rows instead of buffering"),
            workspace("migrate-postgres-16", repo: "api-server", tool: .conductor, size: 5.4, artifacts: [("target", 4.9)], dirty: 3, ahead: 2, hours: 12,
                      subject: "Update the schema migration runner", conductor: "ready"),
            workspace("hotfix-session-timeout", repo: "api-server", tool: .claude, size: 0.6, artifacts: [("target", 0.4)], merged: true, hours: 40, subject: "Extend the idle session timeout"),
            workspace("android-deeplinks", repo: "mobile-app", tool: .superset, size: 1.9, artifacts: [("build", 1.4)], ahead: 2, hours: 30, subject: "Handle universal links on Android"),
            workspace("tidy-lint-config", repo: "docs-site", tool: .claude, size: 0.2, artifacts: [], hours: 24 * 5, subject: "Initial commit"),
        ]
        func repoEntry(_ name: String, artifacts: [(String, Double)], hours: Double) -> Entry {
            let path = "\(Demo.user)/Developer/\(name)"
            var e = Entry(id: "repo:" + path, kind: .repo, name: name, path: path, repoPath: path, repoName: name, branch: nil, sources: [.git], note: "Main checkout")
            e.artifacts = artifacts.map { Artifact(path: path + "/" + $0.0, bytes: gb($0.1)) }
            e.size = e.artifactBytes; e.lastActivity = ago(hours: hours); e.measured = true
            return e
        }
        list += [repoEntry("api-server", artifacts: [("target", 38.2)], hours: 0.5), repoEntry("web-app", artifacts: [("node_modules", 2.4)], hours: 3),
                 repoEntry("mobile-app", artifacts: [("Pods", 1.1)], hours: 20)]

        func cache(_ name: String, _ note: String, _ size: Double, _ source: Source) -> Entry {
            var e = Entry(id: "ca:" + name, kind: .cache, name: name, path: "\(Demo.user)/Library/Caches/\(name)", repoPath: nil, repoName: "App caches",
                          branch: nil, sources: [source], note: note)
            e.size = gb(size); e.measured = true
            Classifier.classify(&e, staleDays: 14)
            return e
        }
        list += [cache("Xcode DerivedData", "Build products, rebuilt on demand", 12.4, .dev), cache("npm cache", "Re-downloaded when needed", 3.8, .dev),
                 cache("Claude edit-rewind history", "File snapshots used to rewind edits", 1.1, .claude)]
        entries = list.sorted { $0.name < $1.name }

        // MARK: Disk map

        let h = home
        func hot(_ rel: String, _ size: Double) -> Hotspot {
            let path = h + "/" + rel
            let d = StorageMapper.describe(path)
            return Hotspot(path: path, size: gb(size), hint: d?.hint, cleanable: d?.clean ?? false)
        }
        map = StorageMapResult(
            groups: [
                MapGroup(name: "Developer", detail: "Your code and build output", size: gb(318), colorName: "blue"),
                MapGroup(name: "Library", detail: "App data, caches and containers", size: gb(96), colorName: "purple"),
                MapGroup(name: "Tool folders", detail: ".cache, .codex, .rustup…", size: gb(31), colorName: "teal"),
                MapGroup(name: "Your files", detail: "Documents, Downloads, Movies…", size: gb(22), colorName: "pink"),
                MapGroup(name: "Applications", detail: "Installed apps", size: gb(18), colorName: "indigo"),
            ],
            hotspots: [hot("Developer/api-server/target", 214), hot("Library/Group Containers/orbstack/data", 62), hot("Developer/api-server/.claude", 38),
                       hot("Library/Application Support", 27), hot(".codex", 12.4), hot(".cache", 9.8), hot(".rustup", 6.8), hot("Library/Caches", 4.6)],
            homeTotal: gb(467), apps: gb(18))

        // MARK: Disk history (a week of slow decline, with a cleanup in the middle)

        var s: [DiskSample] = []
        for i in stride(from: 24 * 12, through: 0, by: -1) {   // every 5 minutes for 24 hours
            let t = now.addingTimeInterval(-Double(i) * 300)
            let hoursAgo = Double(i) / 12
            var free = 574.0 + (24 - hoursAgo) * 0.4 + sin(hoursAgo * 1.7) * 1.2
            if hoursAgo < 7 { free += 36 }   // freed by a cleanup seven hours ago
            s.append(DiskSample(t: t, free: gb(free), used: gb(994.6 - free)))
        }
        samples = s

        // MARK: Agents

        func agent(_ pid: Int32, _ kind: AgentKind, _ state: AgentState, _ cwd: String, _ title: String, cost: Double, cpu: Double, mb: Double, minutes: Double) -> AgentProc {
            var a = AgentProc(pid: pid, ppid: 1, kind: kind, elapsed: minutes * 60, cpu: cpu, rssBytes: Int64(mb * 1_048_576), cwd: cwd, command: kind.rawValue.lowercased())
            a.state = state; a.title = title; a.cost = cost; a.lastEvent = now.addingTimeInterval(state == .idle ? -720 : -8)
            return a
        }
        let apiFix = pathFor(.claude, repo: "api-server", name: "fix-billing-retry")
        agents = [
            agent(41022, .claude, .needsInput, apiFix, "Add retry with backoff to the billing webhook handler", cost: 4.82, cpu: 1.2, mb: 210, minutes: 96),
            agent(41377, .codex, .working, pathFor(.codex, repo: "api-server", name: "perf-cache-layer"), "Cache hot product queries for 30 seconds", cost: 2.17, cpu: 14.6, mb: 340, minutes: 41),
            agent(40911, .claude, .working, pathFor(.superset, repo: "mobile-app", name: "mobile-onboarding"), "Add the permissions step to onboarding", cost: 1.35, cpu: 6.1, mb: 180, minutes: 22),
            agent(41544, .codex, .working, pathFor(.codex, repo: "web-app", name: "spike-queue"), "Try a durable queue for exports", cost: 0.92, cpu: 8.3, mb: 290, minutes: 17),
            agent(39880, .claude, .idle, pathFor(.claude, repo: "docs-site", name: "docs-search-polish"), "Improve docs search ranking", cost: 0.64, cpu: 0.0, mb: 120, minutes: 188),
            {
                var m1 = AgentProc(pid: 40100, ppid: 40000, kind: .mcp, elapsed: 3 * 86_400, cpu: 0.2, rssBytes: 52 << 20, cwd: "\(Demo.user)/Developer/api-server", command: "mcp-server-postgres")
                m1.state = .unknown; return m1
            }(),
            {
                var m2 = AgentProc(pid: 40101, ppid: 40000, kind: .mcp, elapsed: 3 * 86_400, cpu: 0.0, rssBytes: 38 << 20, cwd: "\(Demo.user)/Developer/web-app", command: "mcp-server-github")
                m2.state = .unknown; return m2
            }(),
        ]
        lastAgentKey = agents.map(\.displayKey)

        // MARK: Usage

        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let cal = Calendar.current
        var rows: [UsageRow] = []
        for d in 0..<30 {
            let day = cal.startOfDay(for: now.addingTimeInterval(-Double(d) * 86_400))
            let weekend = cal.isDateInWeekend(day)
            let load = weekend ? 0.25 : 1.0
            for (agentTool, model, project, base) in [(AgentTool.claude, "claude-sonnet-5-5", "api-server", 210_000.0), (.claude, "claude-sonnet-5-5", "web-app", 110_000),
                                                      (.claude, "claude-opus-5-5", "api-server", 26_000), (.codex, "gpt-5.5", "mobile-app", 150_000)] {
                let out = Int(base * load * (0.5 + rnd()) * (d == 0 ? 0.8 : 1))
                guard out > 1000 else { continue }
                rows.append(UsageRow(agent: agentTool, day: day, model: model, project: project, session: "s\(d)-\(project)", input: out * 4,
                                     output: out, cacheRead: out * 60, cacheWrite: agentTool == .claude ? out * 6 : 0))
            }
        }
        usage = rows
        let titles = ["Add retry with backoff to the billing webhook handler", "Migrate search to the new index API", "Fix the flaky checkout test on CI",
                      "Move auth middleware to session tokens", "Write the v3 migration guide", "Investigate memory growth in the worker pool"]
        sessions = titles.enumerated().map { i, t in
            SessionInfo(file: "/demo/\(i)", sessionID: "demo-\(i)", agent: i == 1 || i == 4 ? .codex : .claude, title: t, cwd: "\(Demo.user)/Developer/api-server",
                        project: ["api-server", "web-app", "mobile-app"][i % 3], first: ago(hours: Double(i) * 20 + 3), last: ago(hours: Double(i) * 20 + 1),
                        cost: [18.4, 12.9, 9.6, 7.2, 5.1, 3.8][i], tokens: [38_000_000, 26_000_000, 21_000_000, 15_000_000, 11_000_000, 8_000_000][i], bytes: 4_000_000)
        }
        codexLimits = CodexLimits(primaryPct: 34, primaryResets: now.addingTimeInterval(2.5 * 3600), weeklyPct: 22, weeklyResets: now.addingTimeInterval(3 * 86_400))
    }

    /// A cleanup that is partway through, for the activity bar and the progress view.
    func addDemoJob() -> CleanupJob {
        let repo = entries.first { $0.kind == .repo && $0.name == "api-server" }!
        var opts = CleanupOptions(); opts.permanent = true
        let job = CleanupJob(plan: CleanupPlan(mode: .purgeArtifacts, entries: [repo]), options: opts, targets: [repo])
        job.state = .running
        job.status = CleanupStatus(label: "api-server/target", detail: "api-server/target/debug/deps", itemIndex: 1, itemTotal: 1,
                                   freed: 24_400_000_000, total: 38_200_000_000, started: Date().addingTimeInterval(-95), cancelling: false)
        jobs = [job]
        return job
    }
}
