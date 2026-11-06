import Foundation

extension Store {
    /// Finds the installed skills and reads the saved scan results. Cheap enough to run each time the page opens.
    func loadSkills() async {
        guard !Demo.enabled else { return }
        let projects = entries.filter { $0.kind == .repo && $0.exists }.map(\.path)
        let found = await Task.detached(priority: .utility) { SkillCatalog.discover(projects: projects) }.value
        skills = found
        skillScans = await Task.detached(priority: .utility) { SkillScanner.loadCache() }.value
        skillScanner = SkillScanner.locate()
        quarantinedSkills = SkillRemoval.list()
        skillsLoaded = true
    }

    /// Scans in the background at low priority. Each result appears as it arrives and is saved straight away.
    func scanSkills(_ targets: [SkillInfo]) async {
        guard skillScanProgress == nil, !targets.isEmpty, let binary = skillScanner ?? SkillScanner.locate() else { return }
        skillScanProgress = (0, targets.count, "")
        for t in targets { skillErrors[t.realPath] = nil }
        let token = SkillScanner.ScanToken()
        skillScanToken = token
        await Task.detached(priority: .utility) {
            SkillScanner.scanAll(targets, binary: binary, token: token) { skill, result, n in
                Task { @MainActor in
                    switch result {
                    case .success(let c):
                        self.skillScans[skill.realPath] = c
                        let copy = self.skillScans
                        Task.detached(priority: .utility) { SkillScanner.saveCache(copy) }
                    case .failure(let e): self.skillErrors[skill.realPath] = e.localizedDescription
                    }
                    self.skillScanProgress = (n, targets.count, skill.name)
                }
            }
        }.value
        skillScanProgress = nil
        skillScanToken = nil
    }

    /// Stops a running scan. Skills already finished keep their results.
    func stopSkillScan() { skillScanToken?.cancel() }

    /// Only ever called after the user confirmed in the dialog that shows exactly what will be installed.
    func installScanner() async -> String {
        skillInstalling = true
        let r = await Task.detached(priority: .userInitiated) { SkillScanner.install() }.value
        skillScanner = SkillScanner.locate()
        skillInstalling = false
        return r.message
    }

    /// Takes skills out of use. Plugin and project skills are skipped, and the caller has shown the user what is skipped.
    func removeSkills(_ list: [SkillInfo], permanent: Bool) -> (done: Int, failed: Int) {
        var done = 0, failed = 0
        for s in SkillRemoval.plan(list).removable {
            do { try SkillRemoval.remove(s, scan: SkillScanner.current(s, in: skillScans), permanent: permanent); done += 1 } catch { failed += 1 }
        }
        quarantinedSkills = SkillRemoval.list()
        return (done, failed)
    }

    func restoreSkill(_ q: QuarantinedSkill) -> String? {
        do { try SkillRemoval.restore(q); quarantinedSkills = SkillRemoval.list(); return nil } catch { return error.localizedDescription }
    }

    func deleteQuarantined(_ q: QuarantinedSkill) { SkillRemoval.delete(q); quarantinedSkills = SkillRemoval.list() }
}
