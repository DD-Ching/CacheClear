//
//  OffloadManager.swift
//  CacheClear
//
//  Owns the GitHub Offload & Reclaim pipeline: scan → classify → (advise) →
//  snapshot → push → VERIFY → reclaim, plus restore. The verification gate is
//  the load-bearing safety property: nothing local is ever deleted unless the
//  remote provably contains every local commit, branch and tag.
//

import Foundation
import AppKit
import Combine

enum OffloadStep: Equatable {
    case rescue, snapshot, remote, push, verify, reclaim

    var labelKey: String {
        switch self {
        case .rescue: return "offload.step.rescue"
        case .snapshot: return "offload.step.snapshot"
        case .remote: return "offload.step.remote"
        case .push: return "offload.step.push"
        case .verify: return "offload.step.verify"
        case .reclaim: return "offload.step.reclaim"
        }
    }
}

enum OffloadError: LocalizedError {
    case blocked(String)
    case pushFailed(String)
    case verifyFailed
    case ghUnavailable
    case ghCreateFailed(String)
    case restoreCollision

    var errorDescription: String? {
        switch self {
        case .blocked(let r): return String(format: NSLocalizedString("offload.error.blocked", comment: ""), r)
        case .pushFailed(let m): return String(format: NSLocalizedString("offload.error.push", comment: ""), m)
        case .verifyFailed: return NSLocalizedString("offload.error.verify", comment: "")
        case .ghUnavailable: return NSLocalizedString("offload.error.gh_unavailable", comment: "")
        case .ghCreateFailed(let m): return String(format: NSLocalizedString("offload.error.gh_create", comment: ""), m)
        case .restoreCollision: return NSLocalizedString("offload.error.restore_collision", comment: "")
        }
    }
}

struct RepoResult: Equatable {
    enum State: Equatable { case offloaded, failed }
    let state: State
    let message: String
}

@MainActor
final class OffloadManager: ObservableObject {
    static let shared = OffloadManager()

    enum Phase: Equatable {
        case idle
        case scanning
        case offloading(repo: String, step: OffloadStep)
        case restoring(repo: String)
    }

    @Published var rootURL: URL?
    @Published var repos: [ProjectRepo] = []
    @Published var phase: Phase = .idle
    @Published var statusLine: String = ""
    @Published var lastError: String?
    @Published var results: [String: RepoResult] = [:]
    @Published var offloads: [OffloadManifest] = []

    private let runner = GitCommandRunner.shared
    private let settings = OffloadSettings.shared
    private let advisor: OffloadAdvisor = AdvisorFactory.make()
    private let fm = FileManager.default
    private var scanGeneration = 0

    var isBusy: Bool { phase != .idle }
    var isModelBackedAdvisor: Bool { AdvisorFactory.isModelBacked }

    var selectedRepos: [ProjectRepo] {
        repos.filter { $0.isSelected && results[$0.id] == nil }
    }
    var reclaimableBytes: UInt64 {
        selectedRepos.reduce(0) { $0 + $1.sizeBytes }
    }

    private init() {
        if let p = settings.projectsRootPath {
            rootURL = URL(fileURLWithPath: p)
        }
        offloads = loadIndex().filter { $0.isStillOffloaded }
    }

    // MARK: - Selection

    func setRoot(_ url: URL) {
        rootURL = url
        settings.projectsRootPath = url.path
        Task { await scan() }
    }

    func toggle(_ id: String) {
        guard let i = repos.firstIndex(where: { $0.id == id }) else { return }
        guard repos[i].report.status.isManuallySelectable else { return }
        repos[i].isSelected.toggle()
    }

    func autoSelect() {
        let threshold = settings.inactiveDays
        for i in repos.indices {
            let r = repos[i]
            repos[i].isSelected = r.report.status.isAutoSelectable && (r.ageDays ?? 0) >= threshold
        }
    }

    /// Tick every repo the user is allowed to offload (skips already-offloaded).
    func selectAllEligible() {
        for i in repos.indices where repos[i].report.status.isManuallySelectable && results[repos[i].id] == nil {
            repos[i].isSelected = true
        }
    }

    func deselectAll() {
        for i in repos.indices { repos[i].isSelected = false }
    }

    var eligibleCount: Int {
        repos.filter { $0.report.status.isManuallySelectable && results[$0.id] == nil }.count
    }
    var confirmedCount: Int {
        repos.filter { $0.preflight == .confirmed || $0.preflight == .willCreateRepo }.count
    }

    // MARK: - Scan & classify

    func scan() async {
        guard let root = rootURL else { return }
        scanGeneration += 1
        let gen = scanGeneration
        phase = .scanning
        results = [:]
        repos = []
        let paths = discoverRepoPaths(under: root)
        var found: [ProjectRepo] = []
        for p in paths {
            statusLine = String(format: NSLocalizedString("offload.scanning_format", comment: ""),
                                (p as NSString).lastPathComponent)
            if let repo = await inspect(path: p, root: root) {
                found.append(repo)
            }
        }
        found.sort { ($0.ageDays ?? -1) > ($1.ageDays ?? -1) }
        repos = found
        autoSelect()
        statusLine = ""
        phase = .idle
        await refreshOffloads()
        // The window is now interactive; confirm pushability over the network in
        // the background and update each badge as it resolves.
        await preflightEligible(gen: gen)
    }

    /// Network confirmation that each eligible repo can actually be pushed. Runs
    /// after the (fast, local) scan so the auto-selected list is verified, not
    /// just guessed. A repo that turns out to be behind/diverged/unreachable is
    /// flagged and de-selected — the extra layer of insurance.
    private func preflightEligible(gen: Int) async {
        for i in repos.indices {
            let s = repos[i].report.status
            guard s == .safeToOffload || s == .needsPushFirst || s == .noRemote else { continue }
            repos[i].preflight = repos[i].report.hasRemote ? .checking : .willCreateRepo
        }
        let targets = repos.filter { $0.preflight == .checking }.map(\.id)
        for id in targets {
            if gen != scanGeneration { return }
            guard let idx = repos.firstIndex(where: { $0.id == id }) else { continue }
            let repo = repos[idx]
            statusLine = String(format: NSLocalizedString("offload.preflight_format", comment: ""), repo.name)
            let status = await preflightOne(repo)
            if gen != scanGeneration { return }
            guard let idx2 = repos.firstIndex(where: { $0.id == id }) else { continue }
            repos[idx2].preflight = status
            if case .problem = status {
                repos[idx2].report.status = .conflictRisk
                repos[idx2].isSelected = false
            }
        }
        if gen == scanGeneration { statusLine = "" }
    }

    private func preflightOne(_ repo: ProjectRepo) async -> PreflightStatus {
        let dir = URL(fileURLWithPath: repo.path)
        guard repo.report.hasRemote else { return .willCreateRepo }
        if repo.report.isEmptyRepo { return .confirmed }   // initial push creates everything
        let branch = repo.report.defaultBranch
        let ref = branch.isEmpty ? "HEAD" : "refs/heads/\(branch)"
        guard let ls = try? await runner.git(["ls-remote", "origin", ref], in: dir, network: true), ls.ok else {
            return .problem(NSLocalizedString("offload.preflight.unreachable", comment: ""))
        }
        if ls.out.isEmpty { return .confirmed }            // branch not on remote yet → push creates it
        let remoteSHA = ls.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
        guard !remoteSHA.isEmpty else { return .confirmed }
        // Remote tip already contained in our history ⇒ a plain push fast-forwards.
        if let anc = try? await runner.git(["merge-base", "--is-ancestor", remoteSHA, "HEAD"], in: dir), anc.ok {
            return .confirmed
        }
        return .problem(NSLocalizedString("offload.preflight.behind", comment: ""))
    }

    private func discoverRepoPaths(under root: URL) -> [String] {
        let children = (try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        var out: [String] = []
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if fm.fileExists(atPath: child.appendingPathComponent(".git").path) {
                out.append(child.path)
            }
        }
        return out.sorted()
    }

    private func inspect(path: String, root: URL) async -> ProjectRepo? {
        let dir = URL(fileURLWithPath: path)

        // Must be a real work tree.
        guard let wt = try? await runner.git(["rev-parse", "--is-inside-work-tree"], in: dir),
              wt.ok, wt.out == "true" else { return nil }
        let toplevel = (try? await runner.git(["rev-parse", "--show-toplevel"], in: dir).out) ?? path
        let topURL = URL(fileURLWithPath: toplevel)

        // Skip linked worktrees / submodules (.git is a file, not a dir) — they
        // are handled via their superproject, never offloaded standalone.
        var isDirFlag: ObjCBool = false
        let dotGit = topURL.appendingPathComponent(".git").path
        if fm.fileExists(atPath: dotGit, isDirectory: &isDirFlag), !isDirFlag.boolValue {
            return nil
        }

        var report = RepoSafetyReport()

        // Remote
        if let url = try? await runner.git(["remote", "get-url", "origin"], in: topURL), url.ok, !url.out.isEmpty {
            report.hasRemote = true
            report.remoteIsGitHub = url.out.contains("github.com")
        }
        let remoteURL = report.hasRemote ? (try? await runner.git(["remote", "get-url", "origin"], in: topURL).out) : nil

        // Branch / detached / empty
        let symRef = try? await runner.git(["symbolic-ref", "--short", "-q", "HEAD"], in: topURL)
        if let s = symRef, s.ok { report.defaultBranch = s.out } else { report.isDetachedHead = true }
        let head = try? await runner.git(["rev-parse", "--verify", "-q", "HEAD"], in: topURL)
        report.isEmptyRepo = !(head?.ok ?? false)
        if report.isEmptyRepo { report.isDetachedHead = false }

        // Mid-operation markers
        let gitDir = (try? await runner.git(["rev-parse", "--absolute-git-dir"], in: topURL).out) ?? dotGit
        func gitFileExists(_ name: String) -> Bool {
            fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(name))
        }
        if gitFileExists("MERGE_HEAD") { report.midOperation = .merge }
        else if gitFileExists("rebase-merge") || gitFileExists("rebase-apply") { report.midOperation = .rebase }
        else if gitFileExists("CHERRY_PICK_HEAD") { report.midOperation = .cherryPick }
        else if gitFileExists("REVERT_HEAD") { report.midOperation = .revert }
        else if gitFileExists("BISECT_LOG") { report.midOperation = .bisect }

        // Dirty / untracked
        if let st = try? await runner.git(["status", "--porcelain=v2", "--untracked-files=all"], in: topURL), st.ok {
            for line in st.stdout.split(separator: "\n") {
                if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                    report.dirtyTrackedCount += 1
                } else if line.hasPrefix("? ") {
                    report.untrackedFiles.append(String(line.dropFirst(2)))
                }
            }
        }

        // Ignored payload (collapsed to directories so node_modules isn't enumerated)
        if let ig = try? await runner.git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], in: topURL), ig.ok {
            for line in ig.stdout.split(separator: "\n") {
                let p = String(line)
                report.ignoredFiles.append(IgnoredFile(path: p, kind: classifyIgnored(p)))
            }
        }

        // Stashes
        if let stash = try? await runner.git(["stash", "list"], in: topURL), stash.ok {
            report.stashCount = stash.out.isEmpty ? 0 : stash.out.split(separator: "\n").count
        }

        // Submodules
        let gitmodules = topURL.appendingPathComponent(".gitmodules")
        if fm.fileExists(atPath: gitmodules.path) {
            report.submodulesPresent = true
        } else if let sm = try? await runner.git(["submodule", "status"], in: topURL), sm.ok, !sm.out.isEmpty {
            report.submodulesPresent = true
        }

        // LFS
        let attrs = topURL.appendingPathComponent(".gitattributes")
        if let s = try? String(contentsOf: attrs, encoding: .utf8), s.contains("filter=lfs") {
            report.lfsPresent = true
            let v = try? await runner.git(["lfs", "version"], in: topURL)
            report.lfsToolMissing = !(v?.ok ?? false)
        }

        // Unpushed count (stale tracking refs; the live verify gate is authoritative)
        if report.hasRemote {
            let r = try? await runner.git(["rev-list", "--count", "--branches", "--tags", "--not", "--remotes"], in: topURL)
            report.unpushedRefCount = Int(r?.out ?? "") ?? 0
        } else if !report.isEmptyRepo {
            let r = try? await runner.git(["rev-list", "--count", "--all"], in: topURL)
            report.unpushedRefCount = Int(r?.out ?? "") ?? 0
        }

        // Divergence (best-effort, no network)
        if report.hasRemote, !report.isEmptyRepo {
            let ahead = try? await runner.git(["rev-list", "--count", "@{upstream}..HEAD"], in: topURL)
            let behind = try? await runner.git(["rev-list", "--count", "HEAD..@{upstream}"], in: topURL)
            if let b = behind, b.ok, (Int(b.out) ?? 0) > 0, (Int(ahead?.out ?? "0") ?? 0) > 0 {
                report.diverged = true
            }
        }

        classify(&report)

        // Last activity
        var lastActivity: Date?
        if let ts = try? await runner.git(["for-each-ref", "--sort=-committerdate", "--format=%(committerdate:unix)", "refs/heads"], in: topURL).out,
           let first = ts.split(separator: "\n").first, let unix = TimeInterval(first) {
            lastActivity = Date(timeIntervalSince1970: unix)
        } else {
            lastActivity = (try? topURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        }

        let size = await runner.diskUsageBytes(toplevel)
        let rel = relativePath(of: toplevel, under: root)

        return ProjectRepo(
            id: toplevel,
            name: topURL.lastPathComponent,
            path: toplevel,
            relativePath: rel,
            remoteURL: remoteURL,
            lastActivity: lastActivity,
            sizeBytes: size,
            report: report
        )
    }

    private func classify(_ r: inout RepoSafetyReport) {
        if r.midOperation != nil { r.status = .blocked; r.blockingReasons.append(NSLocalizedString("manager.block.midop.headline", comment: "")); return }
        if r.lfsPresent && r.lfsToolMissing { r.status = .blocked; r.blockingReasons.append(NSLocalizedString("manager.block.lfs.headline", comment: "")); return }
        if !r.largeBlobs.isEmpty { r.status = .blocked; return }
        if r.submodulesPresent { r.status = .blocked; r.blockingReasons.append(NSLocalizedString("manager.block.submodule.headline", comment: "")); return }
        if r.diverged { r.status = .conflictRisk; return }
        if !r.secretOrDataIgnored.isEmpty { r.status = .hasLocalOnlySecrets; return }
        if !r.hasRemote { r.status = .noRemote; return }
        if r.unpushedRefCount > 0 || r.dirtyTrackedCount > 0 || !r.untrackedFiles.isEmpty { r.status = .needsPushFirst; return }
        r.status = .safeToOffload
    }

    private func classifyIgnored(_ path: String) -> IgnoredFile.Kind {
        let lower = path.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        let regenerable = ["node_modules", ".next", "build", "dist", "target", ".venv", "pods",
                           "deriveddata", ".build", "vendor", "__pycache__", ".gradle", ".cache"]
        if regenerable.contains(where: { lower.contains($0) }) { return .regenerable }
        let secrets = [".env", "credentials", "service-account", "id_rsa", "id_ed25519",
                       ".pem", ".key", ".p12", ".keystore", ".pfx", "secret"]
        if secrets.contains(where: { name.contains($0) }) { return .secret }
        let data = [".sqlite", ".db", ".dump", ".sql"]
        if data.contains(where: { name.hasSuffix($0) }) { return .data }
        return .other
    }

    // MARK: - Advice (coordination manager)

    func advice(for repo: ProjectRepo) async -> OffloadAdvice {
        let ctx = RepoAdviceContext(repo: repo, humanSize: Self.formatBytes(repo.sizeBytes))
        return await advisor.advise(ctx)
    }

    // MARK: - Offload pipeline

    func offloadSelected() async {
        let targets = selectedRepos
        for repo in targets {
            await offloadOne(repo)
        }
        phase = .idle
        await refreshOffloads()
    }

    private func offloadOne(_ repo: ProjectRepo) async {
        let dir = URL(fileURLWithPath: repo.path)
        func step(_ s: OffloadStep) { phase = .offloading(repo: repo.name, step: s) }

        do {
            // Defence in depth: refuse anything not in an offloadable state.
            switch repo.report.status {
            case .blocked, .conflictRisk, .hasLocalOnlySecrets, .unknown:
                throw OffloadError.blocked(repo.report.blockingReasons.first
                    ?? NSLocalizedString("offload.error.not_eligible", comment: ""))
            case .safeToOffload, .needsPushFirst, .noRemote:
                break
            }

            // Step 0/1 — rescue detached HEAD + materialise stashes as real branches
            step(.rescue)
            if repo.report.isDetachedHead, let sha = try? await runner.git(["rev-parse", "--short", "HEAD"], in: dir).out, !sha.isEmpty {
                _ = try? await runner.git(["branch", "offload/detached-\(sha)", "HEAD"], in: dir)
            }
            for i in 0..<repo.report.stashCount {
                _ = try? await runner.git(["branch", "offload/stash-\(i)", "stash@{\(i)}"], in: dir)
            }

            // Step 2 — snapshot tracked + untracked-not-ignored
            step(.snapshot)
            try await runner.gitChecked(["add", "-A"], in: dir)
            let staged = try await runner.git(["diff", "--cached", "--quiet"], in: dir)
            if !staged.ok {  // non-zero ⇒ there is something staged
                let ts = ISO8601DateFormatter().string(from: Date())
                try await runner.gitChecked(["commit", "-m", "CacheClear offload snapshot \(ts)", "--no-verify"], in: dir)
            }
            // Ensure a branch exists (covers the empty-repo first-commit case)
            let hasHead = try await runner.git(["symbolic-ref", "-q", "HEAD"], in: dir)
            if !hasHead.ok {
                try await runner.gitChecked(["checkout", "-b", "main"], in: dir)
            }

            // Step 5 — ensure a remote, creating a PRIVATE repo if necessary
            step(.remote)
            var remoteURL = repo.remoteURL
            if remoteURL == nil {
                guard settings.autoCreatePrivate else {
                    throw OffloadError.blocked(NSLocalizedString("offload.error.no_remote", comment: ""))
                }
                guard await runner.isGHAvailable else { throw OffloadError.ghUnavailable }
                let res = try await runner.gh(["repo", "create", repo.name, "--private", "--source", ".", "--remote", "origin", "--push"], in: dir)
                guard res.ok else { throw OffloadError.ghCreateFailed(res.message) }
                remoteURL = try? await runner.git(["remote", "get-url", "origin"], in: dir).out
            }

            // Step 6 — push every branch + tag (plain push: never overwrite the remote)
            step(.push)
            let pushAll = try await runner.git(["push", "--all", "origin"], in: dir, network: true)
            guard pushAll.ok else { throw OffloadError.pushFailed(pushAll.message) }
            _ = try? await runner.git(["push", "--tags", "origin"], in: dir, network: true)

            // Step 7 — VERIFY the remote holds everything (the delete gate)
            step(.verify)
            guard try await verifyRemoteHasEverything(dir: dir) else { throw OffloadError.verifyFailed }

            // Step 8 — reclaim local disk, leave the restore stub
            step(.reclaim)
            let manifest = try await reclaim(repo: repo, dir: dir, remoteURL: remoteURL ?? repo.remoteURL ?? "")
            results[repo.id] = RepoResult(state: .offloaded,
                                          message: String(format: NSLocalizedString("offload.result.reclaimed_format", comment: ""),
                                                          Self.formatBytes(manifest.reclaimedBytes)))
        } catch {
            results[repo.id] = RepoResult(state: .failed, message: error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    /// ALL gates must pass or we return false and the caller refuses to delete.
    private func verifyRemoteHasEverything(dir: URL) async throws -> Bool {
        _ = try await runner.git(["fetch", "--prune", "--tags", "origin"], in: dir, network: true)
        // (B) Primary proof: no local commit/branch/tag is absent from the remote.
        let missing = try await runner.git(["rev-list", "--branches", "--tags", "--not", "--remotes=origin"], in: dir)
        guard missing.ok, missing.out.isEmpty else { return false }
        // (F) Working tree is clean — the snapshot captured everything trackable.
        let status = try await runner.git(["status", "--porcelain=v2", "--untracked-files=all"], in: dir)
        guard status.ok, status.out.isEmpty else { return false }
        // (E) Network truth: the server itself reports refs.
        let ls = try await runner.git(["ls-remote", "--heads", "--tags", "origin"], in: dir, network: true)
        guard ls.ok, !ls.out.isEmpty else { return false }
        return true
    }

    private func reclaim(repo: ProjectRepo, dir: URL, remoteURL: String) async throws -> OffloadManifest {
        let head = (try? await runner.git(["rev-parse", "HEAD"], in: dir).out) ?? ""
        let branch = (try? await runner.git(["symbolic-ref", "--short", "-q", "HEAD"], in: dir).out) ?? repo.report.defaultBranch
        var pushedRefs: [String: String] = [:]
        if let refs = try? await runner.git(["for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads", "refs/tags"], in: dir).out {
            for line in refs.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2 { pushedRefs[String(parts[0])] = String(parts[1]) }
            }
        }
        var visibility: String?
        if await runner.isGHAvailable,
           let v = try? await runner.gh(["repo", "view", "--json", "visibility", "-q", ".visibility"], in: dir), v.ok {
            visibility = v.out
        }

        let manifest = OffloadManifest(
            projectName: repo.name,
            originalPath: repo.path,
            remoteURL: remoteURL,
            sshURL: nil,
            defaultBranch: branch,
            headSHA: head,
            pushedRefs: pushedRefs,
            repoVisibility: visibility,
            reclaimedBytes: repo.sizeBytes,
            deletionMode: settings.deletionModeString,
            offloadedAt: Date(),
            appVersion: Self.appVersion(),
            verifiedRemote: true,
            backedUpSecrets: []
        )

        // Reclaim the whole working tree (Trash by default), then recreate the
        // directory and drop the stub so the original path stays meaningful.
        if settings.permanentDelete {
            try fm.removeItem(at: dir)
        } else {
            var resulting: NSURL?
            try fm.trashItem(at: dir, resultingItemURL: &resulting)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeStub(manifest)
        appendToIndex(manifest)
        return manifest
    }

    // MARK: - Stub + index

    private func writeStub(_ m: OffloadManifest) throws {
        let dir = URL(fileURLWithPath: m.originalPath)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: dir.appendingPathComponent(OffloadManifest.stubFileName))
        if let data = restoreReadme(m).data(using: .utf8) {
            try data.write(to: dir.appendingPathComponent(OffloadManifest.readmeFileName))
        }
    }

    private func restoreReadme(_ m: OffloadManifest) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        return """
        # \(m.projectName) — 已由 CacheClear 卸載

        這個資料夾的本機內容已經安全推送到 GitHub 後移除,以釋放磁碟空間。

        - 遠端: \(m.remoteURL)
        - 分支: \(m.defaultBranch)
        - HEAD: \(m.headSHA)
        - 卸載時間: \(df.string(from: m.offloadedAt))
        - 回收空間: \(Self.formatBytes(m.reclaimedBytes))
        - 刪除方式: \(m.deletionMode == "trash" ? "移至垃圾桶(可從垃圾桶復原)" : "永久刪除")

        ## 還原方式

        在 CacheClear 選單選擇「還原已卸載專案…」,或手動執行:

        ```
        cd "\(((m.originalPath as NSString).deletingLastPathComponent))"
        rm -rf "\(m.projectName)"
        git clone \(m.remoteURL) "\(m.projectName)"
        ```

        ---
        This project was offloaded to GitHub by CacheClear to reclaim disk space.
        Run `git clone \(m.remoteURL)` to restore it.
        """
    }

    private func appSupportDir() -> URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CacheClear", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func indexURL() -> URL { appSupportDir().appendingPathComponent("offloads.json") }

    func loadIndex() -> [OffloadManifest] {
        guard let data = try? Data(contentsOf: indexURL()) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([OffloadManifest].self, from: data)) ?? []
    }

    private func saveIndex(_ all: [OffloadManifest]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(all) { try? data.write(to: indexURL()) }
    }

    private func appendToIndex(_ m: OffloadManifest) {
        var all = loadIndex()
        all.removeAll { $0.originalPath == m.originalPath }
        all.append(m)
        saveIndex(all)
    }

    func refreshOffloads() async {
        let all = loadIndex().filter { $0.isStillOffloaded }
        saveIndex(all)
        offloads = all.sorted { $0.offloadedAt > $1.offloadedAt }
    }

    // MARK: - Restore

    func restore(_ m: OffloadManifest) async {
        phase = .restoring(repo: m.projectName)
        defer { phase = .idle }
        let dir = URL(fileURLWithPath: m.originalPath)
        let parent = dir.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".cacheclear-restore-\(m.projectName)-\(UUID().uuidString.prefix(6))")
        do {
            // Only restore over a directory that holds nothing but our stub.
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let onlyStub = contents.allSatisfy {
                $0 == OffloadManifest.stubFileName || $0 == OffloadManifest.readmeFileName || $0 == ".DS_Store"
            }
            guard onlyStub else { throw OffloadError.restoreCollision }

            try await runner.gitChecked(["clone", m.remoteURL, temp.path], in: parent, network: true)
            if !m.defaultBranch.isEmpty {
                _ = try? await runner.git(["checkout", m.defaultBranch], in: temp)
            }
            try fm.removeItem(at: dir)
            try fm.moveItem(at: temp, to: dir)

            for s in m.backedUpSecrets {
                let from = URL(fileURLWithPath: s.vaultPath)
                let to = dir.appendingPathComponent(s.relativePath)
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: from, to: to)
            }

            var all = loadIndex()
            all.removeAll { $0.originalPath == m.originalPath }
            saveIndex(all)
            offloads = all.filter { $0.isStillOffloaded }
        } catch {
            try? fm.removeItem(at: temp)
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func relativePath(of path: String, under root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if path.hasPrefix(rootPath) { return String(path.dropFirst(rootPath.count)) }
        return (path as NSString).lastPathComponent
    }

    static func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024, mb = kb / 1024, gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", kb)
    }
}
