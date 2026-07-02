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
    case deleteNotProven
    case noRemoteForDelete

    var errorDescription: String? {
        switch self {
        case .blocked(let r): return String(format: NSLocalizedString("offload.error.blocked", comment: ""), r)
        case .pushFailed(let m): return String(format: NSLocalizedString("offload.error.push", comment: ""), m)
        case .verifyFailed: return NSLocalizedString("offload.error.verify", comment: "")
        case .ghUnavailable: return NSLocalizedString("offload.error.gh_unavailable", comment: "")
        case .ghCreateFailed(let m): return String(format: NSLocalizedString("offload.error.gh_create", comment: ""), m)
        case .restoreCollision: return NSLocalizedString("offload.error.restore_collision", comment: "")
        case .deleteNotProven: return NSLocalizedString("offload.error.delete_not_proven", comment: "")
        case .noRemoteForDelete: return NSLocalizedString("offload.error.no_remote_delete", comment: "")
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

    /// Position in a multi-repo offload queue, for "project 2 of 5" progress.
    struct QueueProgress: Equatable {
        let done: Int
        let total: Int
    }

    @Published var rootURL: URL?
    @Published var scanScopeLabel: String = ""
    @Published var repos: [ProjectRepo] = []
    @Published var phase: Phase = .idle
    @Published var statusLine: String = ""
    @Published var lastError: String?
    @Published var results: [String: RepoResult] = [:]
    @Published var offloads: [OffloadManifest] = []
    @Published var mapItems: [MapItem] = []
    @Published var sessionReclaimed: UInt64 = 0
    @Published var queueProgress: QueueProgress?
    /// Bumped by the menu bar's "Restore" item; the offload window switches to
    /// the Restore tab when it changes.
    @Published private(set) var restoreTabRequests = 0

    private let runner = GitCommandRunner.shared
    private let settings = OffloadSettings.shared
    private let advisor: OffloadAdvisor = AdvisorFactory.make()
    private let fm = FileManager.default
    private var scanGeneration = 0
    private var sizeCache: [String: UInt64] = [:]
    private var mapTask: Task<Void, Never>?
    private var cancelRequested = false
    private var scanCancelRequested = false

    /// How many repos are inspected/preflighted/sized concurrently. The wall
    /// clock win comes from overlapping subprocess waits; beyond this the Mac
    /// just thrashes on process spawns.
    private static let scanConcurrency = 6

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
        Task { await scan(roots: [url], label: url.path) }
    }

    /// Common places projects/repos live, used on first open so the user doesn't
    /// have to pick a folder. Each is scanned at depth-1 (immediate children),
    /// so e.g. a repo sitting directly in the home folder is found, but not the
    /// entire home tree. Only locations that actually exist are returned.
    func defaultScanRoots() -> [URL] {
        let home = fm.homeDirectoryForCurrentUser
        // Documents is intentionally omitted from the auto-default to cut the
        // number of one-time macOS permission prompts; it can be added via
        // "Choose Folder". Developer/Projects/Sites/Code are not TCC-protected.
        let candidates = [
            home,
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Developer"),
            home.appendingPathComponent("Projects"),
            home.appendingPathComponent("Sites"),
            home.appendingPathComponent("Code"),
            home.appendingPathComponent("repos"),
        ]
        return candidates.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    func scanDefaults() async {
        rootURL = nil
        settings.projectsRootPath = nil
        await scan(roots: defaultScanRoots(),
                   label: NSLocalizedString("offload.scope.defaults", comment: ""))
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
            repos[i].isSelected = r.report.status.isAutoSelectable
                && (r.ageDays ?? 0) >= threshold
                && !r.isRecentlyActive          // never auto-pick something you touched in the last 3 days
        }
    }

    /// Tick every repo the user is allowed to offload (skips already-offloaded and
    /// anything touched in the last 3 days — those need a deliberate manual tick).
    func selectAllEligible() {
        for i in repos.indices where repos[i].report.status.isManuallySelectable
            && results[repos[i].id] == nil && !repos[i].isRecentlyActive {
            repos[i].isSelected = true
        }
    }

    func deselectAll() {
        for i in repos.indices { repos[i].isSelected = false }
    }

    /// Bulk-select by size: every eligible repo ≥ minBytes is selected, smaller
    /// ones deselected. Drives the size-threshold slider; manual toggles run after.
    func selectBySizeThreshold(minBytes: UInt64) {
        for i in repos.indices where repos[i].report.status.isManuallySelectable && results[repos[i].id] == nil {
            // Recently-active repos are never bulk-selected by size, even if large.
            repos[i].isSelected = repos[i].sizeBytes >= minBytes && !repos[i].isRecentlyActive
        }
    }

    /// Eligible repos (manually selectable, not yet offloaded), biggest first.
    var eligibleRepos: [ProjectRepo] {
        repos.filter { $0.report.status.isManuallySelectable && results[$0.id] == nil }
             .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var eligibleCount: Int {
        repos.filter { $0.report.status.isManuallySelectable && results[$0.id] == nil }.count
    }
    var confirmedCount: Int {
        repos.filter { $0.preflight == .confirmed || $0.preflight == .willCreateRepo }.count
    }

    // MARK: - Scan & classify

    /// Rescan: re-uses the chosen folder, or the default locations if none chosen.
    func scan() async {
        if let r = rootURL {
            await scan(roots: [r], label: r.path)
        } else {
            await scanDefaults()
        }
    }

    private func scan(roots: [URL], label: String) async {
        scanGeneration += 1
        let gen = scanGeneration
        scanCancelRequested = false
        scanScopeLabel = label
        phase = .scanning
        results = [:]
        repos = []
        var seen = Set<String>()
        var found: [ProjectRepo] = []

        var pending: [(path: String, root: URL)] = []
        for root in roots {
            for p in discoverRepoPaths(under: root) { pending.append((p, root)) }
        }

        // Inspect repos concurrently: each inspection is ~15 subprocess waits,
        // so overlapping them cuts scan wall-clock by roughly the concurrency
        // factor. Results land on the main actor as they complete.
        var scanned = 0
        var cancelled = false
        await withTaskGroup(of: ProjectRepo?.self) { group in
            var next = 0
            func addNext() {
                guard next < pending.count else { return }
                let (p, root) = pending[next]
                next += 1
                group.addTask { await self.inspect(path: p, root: root) }
            }
            for _ in 0..<Self.scanConcurrency { addNext() }
            for await repo in group {
                if gen != scanGeneration { group.cancelAll(); return }   // superseded by a newer scan
                if let repo, !seen.contains(repo.id) {
                    seen.insert(repo.id)
                    found.append(repo)
                }
                if scanCancelRequested {
                    cancelled = true
                    group.cancelAll()
                    break
                }
                scanned += 1
                statusLine = String(format: NSLocalizedString("offload.scanning_count_format", comment: ""),
                                    scanned, pending.count)
                addNext()
            }
        }
        guard gen == scanGeneration else { return }

        // A cancelled scan keeps whatever it already discovered.
        found.sort { $0.sizeBytes > $1.sizeBytes }   // biggest first
        repos = found
        autoSelect()
        statusLine = ""
        phase = .idle
        await refreshOffloads()
        guard !cancelled else { return }
        // The window is now interactive; confirm pushability over the network in
        // the background and update each badge as it resolves.
        await preflightEligible(gen: gen)
    }

    /// Abandon the current scan (the window's Cancel button). Anything already
    /// discovered stays; in-flight git calls are cancelled.
    func cancelScan() {
        guard phase == .scanning else { return }
        scanCancelRequested = true
    }

    /// Ask a running multi-repo offload to stop after the CURRENT project
    /// finishes its pipeline. Never interrupts a project mid-flight — a repo is
    /// either fully offloaded (verified) or untouched.
    func cancelQueuedOffloads() {
        cancelRequested = true
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
        let targets = repos.filter { $0.preflight == .checking }
        guard !targets.isEmpty else { return }
        statusLine = String(format: NSLocalizedString("offload.preflight_format", comment: ""),
                            targets[0].name)
        // One ls-remote per repo, several in flight at once — the round trips
        // overlap instead of queueing behind each other.
        await withTaskGroup(of: (String, PreflightStatus).self) { group in
            var next = 0
            func addNext() {
                guard next < targets.count else { return }
                let repo = targets[next]
                next += 1
                group.addTask { (repo.id, await self.preflightOne(repo)) }
            }
            for _ in 0..<Self.scanConcurrency { addNext() }
            for await (id, status) in group {
                if gen != scanGeneration { group.cancelAll(); return }
                if let idx = repos.firstIndex(where: { $0.id == id }) {
                    statusLine = String(format: NSLocalizedString("offload.preflight_format", comment: ""),
                                        repos[idx].name)
                    repos[idx].preflight = status
                    if case .problem = status {
                        repos[idx].report.status = .conflictRisk
                        repos[idx].isSelected = false
                    }
                }
                addNext()
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
        // 30s is plenty for a single ls-remote; the 600s default would let one
        // unreachable host stall the whole preflight pass.
        guard let ls = try? await runner.git(["ls-remote", "origin", ref], in: dir, network: true, timeout: 30), ls.ok else {
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
        var remoteURL: String?
        if let url = try? await runner.git(["remote", "get-url", "origin"], in: topURL), url.ok, !url.out.isEmpty {
            report.hasRemote = true
            report.remoteIsGitHub = url.out.contains("github.com")
            remoteURL = url.out
        }

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

        // Committed gitlinks (mode 160000). .claude/worktrees/* are ephemeral
        // Claude Code agent worktrees — handled automatically by the pipeline.
        // Any other unregistered gitlink (no .gitmodules) is a hard block.
        if let ls = try? await runner.git(["ls-files", "--stage"], in: topURL), ls.ok {
            for line in ls.stdout.split(separator: "\n") where line.hasPrefix("160000 ") {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let path = String(line[line.index(after: tab)...])
                if path.hasPrefix(".claude/worktrees/") {
                    report.strayWorktrees.append(path)
                } else if !report.submodulesPresent {
                    report.unregisteredGitlinks.append(path)
                }
            }
        }

        // LFS
        let attrs = topURL.appendingPathComponent(".gitattributes")
        if let s = try? String(contentsOf: attrs, encoding: .utf8), s.contains("filter=lfs") {
            report.lfsPresent = true
            let v = try? await runner.git(["lfs", "version"], in: topURL)
            report.lfsToolMissing = !(v?.ok ?? false)
        }

        // Blobs over GitHub's 100 MB hard push limit anywhere in history (LFS
        // repos excepted — their big files live in LFS, not as loose blobs).
        // Without this check the push step would fail AFTER the snapshot commit.
        // The output can be one line per object in the repo, so the parse runs
        // OFF the main actor — six of these could otherwise stall the UI at once.
        if !report.isEmptyRepo, !report.lfsPresent,
           let blobs = try? await runner.git(["cat-file", "--batch-all-objects", "--unordered",
                                              "--batch-check=%(objecttype) %(objectsize) %(objectname)"], in: topURL), blobs.ok {
            let output = blobs.stdout
            report.largeBlobs = await Task.detached(priority: .utility) { () -> [String] in
                var found: [String] = []
                for line in output.split(separator: "\n") {
                    let f = line.split(separator: " ")
                    guard f.count == 3, f[0] == "blob", let size = UInt64(f[1]),
                          size > 100 * 1024 * 1024 else { continue }
                    found.append("\(f[2].prefix(10)) (\(ByteFormat.string(size)))")
                    if found.count >= 5 { break }
                }
                return found
            }.value
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

        let size = await DiskUsage.bytes(atPath: toplevel)
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
        // Oversized blobs only block when a push would be NEEDED — a fully
        // pushed repo already got them to the remote somehow, and delete-without-
        // push never pushes at all.
        let wouldNeedPush = !r.hasRemote || r.unpushedRefCount > 0 || r.dirtyTrackedCount > 0 || !r.untrackedFiles.isEmpty
        if !r.largeBlobs.isEmpty && wouldNeedPush {
            r.status = .blocked
            r.blockingReasons.append(NSLocalizedString("manager.block.large.headline", comment: ""))
            return
        }
        if r.submodulesPresent { r.status = .blocked; r.blockingReasons.append(NSLocalizedString("manager.block.submodule.headline", comment: "")); return }
        if !r.unregisteredGitlinks.isEmpty { r.status = .blocked; r.blockingReasons.append(NSLocalizedString("manager.block.gitlink.headline", comment: "")); return }
        if r.diverged { r.status = .conflictRisk; return }
        if !r.secretOrDataIgnored.isEmpty { r.status = .hasLocalOnlySecrets; return }
        if !r.hasRemote { r.status = .noRemote; return }
        if r.unpushedRefCount > 0 || r.dirtyTrackedCount > 0 || !r.untrackedFiles.isEmpty { r.status = .needsPushFirst; return }
        r.status = .safeToOffload
    }

    private func classifyIgnored(_ path: String) -> IgnoredFile.Kind {
        let lower = path.lowercased()
        let name = (path as NSString).lastPathComponent
        let regenerable = ["node_modules", ".next", "build", "dist", "target", ".venv", "pods",
                           "deriveddata", ".build", "vendor", "__pycache__", ".gradle", ".cache"]
        if regenerable.contains(where: { lower.contains($0) }) { return .regenerable }
        if SecretHeuristics.isSecretName(name) { return .secret }
        if SecretHeuristics.isDataName(name) { return .data }
        return .other
    }

    // MARK: - Advice (coordination manager)

    func advice(for repo: ProjectRepo) async -> OffloadAdvice {
        let ctx = RepoAdviceContext(repo: repo, humanSize: ByteFormat.string(repo.sizeBytes))
        return await advisor.advise(ctx)
    }

    // MARK: - Offload pipeline

    func offloadSelected() async {
        // Reentrancy: the button is disabled while busy, but the global hotkey
        // and a double-fired sheet callback are not.
        guard phase == .idle else { return }
        cancelRequested = false
        let targets = selectedRepos
        for (i, repo) in targets.enumerated() {
            if cancelRequested { break }
            queueProgress = QueueProgress(done: i, total: targets.count)
            await offloadOne(repo)
        }
        queueProgress = nil
        cancelRequested = false
        phase = .idle
        await refreshOffloads()
        // Offloaded repos leave the list (their stub now lives in Restore);
        // nothing else on disk changed, so no full rescan is needed. Failures
        // stay visible with their badge.
        repos.removeAll { results[$0.id]?.state == .offloaded }
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
            // Neutralise stray Claude Code agent worktrees first: untrack the
            // committed gitlinks and gitignore the folder so `git status` can
            // verify clean (otherwise their untracked junk keeps the tree dirty
            // forever and the verify gate refuses to reclaim). Their tracked
            // content shares the main repo's objects — already on GitHub — and
            // only regenerable caches live inside; nothing is deleted here, and
            // the change is committed and pushed.
            let worktreesDir = dir.appendingPathComponent(".claude/worktrees")
            if !repo.report.strayWorktrees.isEmpty || fm.fileExists(atPath: worktreesDir.path) {
                _ = try? await runner.git(["rm", "-r", "--cached", "--ignore-unmatch", "--quiet", ".claude/worktrees"], in: dir)
                appendIgnore(".claude/worktrees/", in: dir)
            }
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
                                                          ByteFormat.string(manifest.reclaimedBytes)))
        } catch {
            results[repo.id] = RepoResult(state: .failed, message: error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    /// Reclaim a project's local space WITHOUT pushing — for handed-off projects
    /// where GitHub already has everything. The verify gate STILL runs: if the
    /// local has any commit/branch/tag or uncommitted change the remote lacks,
    /// this refuses and deletes nothing. Goes to Trash by default; leaves the stub.
    func deleteWithoutPush(_ repo: ProjectRepo) async {
        guard phase == .idle else { return }
        let dir = URL(fileURLWithPath: repo.path)
        func step(_ s: OffloadStep) { phase = .offloading(repo: repo.name, step: s) }
        do {
            guard repo.report.hasRemote, let remoteURL = repo.remoteURL, !remoteURL.isEmpty else {
                throw OffloadError.noRemoteForDelete
            }
            switch repo.report.status {
            case .blocked, .hasLocalOnlySecrets:
                throw OffloadError.blocked(repo.report.blockingReasons.first
                    ?? NSLocalizedString("offload.error.not_eligible", comment: ""))
            default:
                break
            }
            // The load-bearing safety: prove the remote already holds everything.
            step(.verify)
            guard try await verifyRemoteHasEverything(dir: dir) else {
                throw OffloadError.deleteNotProven
            }
            step(.reclaim)
            // forceTrash: the confirmation dialog promises "moves to the Trash
            // (recoverable)", so this flow must honor it even when the offload
            // preference says permanent.
            let manifest = try await reclaim(repo: repo, dir: dir, remoteURL: remoteURL, forceTrash: true)
            results[repo.id] = RepoResult(state: .offloaded,
                message: String(format: NSLocalizedString("offload.result.reclaimed_format", comment: ""),
                                ByteFormat.string(manifest.reclaimedBytes)))
        } catch {
            results[repo.id] = RepoResult(state: .failed, message: error.localizedDescription)
            lastError = error.localizedDescription
        }
        phase = .idle
        await refreshOffloads()
    }

    /// ALL gates must pass or we return false and the caller refuses to delete.
    private func verifyRemoteHasEverything(dir: URL) async throws -> Bool {
        // (A) The fetch MUST succeed: the rev-list proof below reads
        // refs/remotes/origin, and a silently failed fetch would let the gate
        // pass on yesterday's stale tracking refs.
        try await runner.gitChecked(["fetch", "--prune", "--tags", "origin"], in: dir, network: true)

        // (B) Primary proof: no local commit — branch, tag, HEAD or stash — is
        // absent from the remote. HEAD covers detached heads; stash entries are
        // commits too and are invisible to --branches, which is exactly how
        // delete-without-push could once drop the only copy of stashed work.
        // Every proof term FAILS CLOSED: "ref absent" (exit 1 from
        // rev-parse --verify -q) is the only acceptable reason to omit one; any
        // other subprocess failure refuses the verify rather than silently
        // shrinking the proof.
        var startPoints = ["--branches", "--tags"]
        let head = try await runner.git(["rev-parse", "--verify", "-q", "HEAD"], in: dir)
        if head.ok {
            startPoints.append("HEAD")
        } else if head.exitCode != 1 {
            return false   // couldn't prove whether HEAD exists — refuse
        }
        let stashRef = try await runner.git(["rev-parse", "--verify", "-q", "refs/stash"], in: dir)
        if stashRef.ok {
            // Stashes exist, so their enumeration is load-bearing: it must succeed.
            let stashes = try await runner.gitChecked(["rev-list", "-g", "stash"], in: dir)
            startPoints += stashes.stdout.split(separator: "\n").map(String.init)
        } else if stashRef.exitCode != 1 {
            return false   // couldn't prove whether stashes exist — refuse
        }
        let missing = try await runner.git(["rev-list"] + startPoints + ["--not", "--remotes=origin"], in: dir)
        guard missing.ok, missing.out.isEmpty else { return false }

        // (F) Working tree is clean — the snapshot captured everything trackable.
        let status = try await runner.git(["status", "--porcelain=v2", "--untracked-files=all"], in: dir)
        guard status.ok, status.out.isEmpty else { return false }

        // (E) Network truth: the server itself reports refs, and every branch WE
        // hold a tracking ref for — the refs the rev-list proof in (B) actually
        // relied on — still exists on the server at the same SHA. This catches a
        // server-side force-push or branch deletion in the window since (A).
        // Remote heads outside our fetch refspec (single-branch/shallow clones)
        // never participated in the proof, so they are deliberately NOT required
        // to have local counterparts — requiring that would false-block every
        // narrow clone of a multi-branch repo.
        let ls = try await runner.git(["ls-remote", "--heads", "--tags", "origin"], in: dir, network: true)
        guard ls.ok, !ls.out.isEmpty else { return false }
        var remoteHeads: [String: String] = [:]   // "main" -> sha
        for line in ls.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count == 2 else { continue }
            let sha = String(parts[0]), ref = String(parts[1])
            guard ref.hasPrefix("refs/heads/") else { continue }   // tags don't move; heads are the risk
            remoteHeads[String(ref.dropFirst("refs/heads/".count))] = sha
        }
        let refs = try await runner.git(["for-each-ref", "--format=%(refname:strip=3) %(objectname)",
                                         "refs/remotes/origin"], in: dir)
        guard refs.ok else { return false }
        for line in refs.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]), sha = String(parts[1])
            if name == "HEAD" { continue }   // origin/HEAD symref, not a branch
            guard remoteHeads[name] == sha else { return false }   // server changed since the fetch
        }
        return true
    }

    private func reclaim(repo: ProjectRepo, dir: URL, remoteURL: String, forceTrash: Bool = false) async throws -> OffloadManifest {
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

        // Safety backstop (in addition to the verify gate): never reclaim a
        // protected path — home, a top-level folder, a system dir or a volume.
        guard PathSafety.isSafeToDelete(dir) else {
            throw OffloadError.blocked(NSLocalizedString("offload.error.protected_path", comment: ""))
        }
        // Permanent delete is only honored when nothing UNPROVEN would be lost:
        // gitignored secrets/data and other non-regenerable ignored files were
        // never pushed to the remote, so if any exist we fall back to the Trash
        // (recoverable) regardless of the permanent-delete setting.
        let hasUnprovenLocalFiles = !repo.report.secretOrDataIgnored.isEmpty
            || repo.report.ignoredFiles.contains { $0.kind == .other }
        var usePermanent = settings.permanentDelete && !forceTrash && !hasUnprovenLocalFiles
        if usePermanent {
            // A secret/db can hide INSIDE a regenerable-named ignored dir (e.g.
            // build/prod.env) which the collapsed directory scan never sees. Do a
            // file-level scan; if found, fall back to Trash so it stays recoverable.
            usePermanent = !(await ignoredTreeHasSecretsOrData(dir: dir))
        }

        // The manifest records what actually happened, not what the setting says
        // — the Trash fallback above must show as "trash" in the restore stub.
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
            deletionMode: usePermanent ? "permanent" : "trash",
            offloadedAt: Date(),
            appVersion: Self.appVersion(),
            verifiedRemote: true,
            backedUpSecrets: []
        )

        // TOCTOU backstop: the verify gate proved the tree clean, but its network
        // round trips take real seconds — anything saved into the tree since then
        // would be deleted unproven. Re-check at the last possible moment.
        let lastStatus = try await runner.git(["status", "--porcelain=v2", "--untracked-files=all"], in: dir)
        guard lastStatus.ok, lastStatus.out.isEmpty else {
            throw OffloadError.deleteNotProven
        }

        // Reclaim the whole working tree, then recreate the directory and drop the
        // stub so the original path stays meaningful. The delete runs off the main
        // thread — trashing is fast, but a permanent rm of a multi-GB tree is not.
        let target = dir
        if usePermanent {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: target)
            }.value
        } else {
            try await Task.detached(priority: .userInitiated) {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
            }.value
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeStub(manifest)
        appendToIndex(manifest)
        return manifest
    }

    /// File-level scan of gitignored files for anything that looks like a secret
    /// or a database, by basename — including files buried inside a regenerable
    /// directory that the collapsed `--directory` scan can't see. Used only before
    /// a PERMANENT reclaim, to keep unproven local-only data recoverable.
    private func ignoredTreeHasSecretsOrData(dir: URL) async -> Bool {
        guard let r = try? await runner.git(
            ["ls-files", "--others", "--ignored", "--exclude-standard"], in: dir), r.ok
        else { return true }   // can't enumerate → assume yes (route to Trash, safe)
        for line in r.stdout.split(separator: "\n") {
            let name = (String(line) as NSString).lastPathComponent
            if SecretHeuristics.isSecretName(name) || SecretHeuristics.isDataName(name) {
                return true
            }
        }
        return false
    }

    /// Append a pattern to .gitignore if not already present (idempotent).
    private func appendIgnore(_ pattern: String, in dir: URL) {
        let gi = dir.appendingPathComponent(".gitignore")
        var contents = (try? String(contentsOf: gi, encoding: .utf8)) ?? ""
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        let present = contents.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == trimmed
        }
        if present { return }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += "# CacheClear: ephemeral Claude Code agent worktrees\n\(pattern)\n"
        try? contents.write(to: gi, atomically: true, encoding: .utf8)
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
        // Localized to the system language (English on an English Mac, etc.).
        let delText = NSLocalizedString(
            m.deletionMode == "trash" ? "offload.readme.del_trash" : "offload.readme.del_permanent",
            comment: "")
        let parent = (m.originalPath as NSString).deletingLastPathComponent
        return String(format: NSLocalizedString("offload.readme_format", comment: ""),
                      m.projectName, m.remoteURL, m.defaultBranch, m.headSHA,
                      df.string(from: m.offloadedAt), ByteFormat.string(m.reclaimedBytes),
                      delText, parent)
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
        do {
            try enc.encode(all).write(to: indexURL())
        } catch {
            // By the time the index is written the repo is already reclaimed —
            // losing the entry would orphan the stub, so at least say so.
            lastError = error.localizedDescription
        }
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

    // MARK: - Map (treemap of disk usage)

    func startMapBuild() {
        mapTask?.cancel()
        let gen = scanGeneration
        mapTask = Task { await buildMap(gen: gen) }
    }

    func stopMapBuild() {
        mapTask?.cancel()
        mapTask = nil
    }

    private struct JunkCandidate {
        let url: URL
        let auto: Bool
        let ownerRepoID: String?   // green block to subtract from (junk inside a repo)
    }

    private func buildMap(gen: Int) async {
        // 1) Repos as green blocks (sizes already known) — render instantly.
        var items: [MapItem] = repos.map { r in
            MapItem(id: r.id, name: r.name, path: r.path, bytes: r.sizeBytes,
                    kind: .repo, repoSelectable: r.report.status.isManuallySelectable,
                    subtitle: r.githubSlug ?? NSLocalizedString("offload.no_remote_pill", comment: ""),
                    badge: NSLocalizedString(r.report.status.labelKey, comment: ""),
                    reason: r.report.status.isManuallySelectable ? nil
                        : (r.report.blockingReasons.first ?? NSLocalizedString("map.reason.locked", comment: "")))
        }
        mapItems = items.sorted { $0.bytes > $1.bytes }
        guard gen == scanGeneration else { return }

        // 2) Gather junk candidates.
        let home = fm.homeDirectoryForCurrentUser
        let repoPaths = Set(repos.map { $0.path })
        var candidates: [JunkCandidate] = []

        // 2a) global caches by absolute path
        for g in JunkClassifier.globalAutoDeletable(home: home) where fm.fileExists(atPath: g.path) {
            candidates.append(JunkCandidate(url: g, auto: true, ownerRepoID: nil))
        }
        // 2b) loose junk directly under each scan root (depth-1), not a repo itself
        let roots = rootURL.map { [$0] } ?? defaultScanRoots()
        for root in roots {
            let children = (try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard !repoPaths.contains(child.path) else { continue }
                appendVerdict(child, ignored: false, owner: nil, to: &candidates)
            }
        }
        // 2c) junk inside known repos — reuse the ignored dirs already collected.
        for r in repos {
            for ig in r.report.ignoredFiles where ig.path.hasSuffix("/") {
                let rel = String(ig.path.dropLast())
                let url = URL(fileURLWithPath: r.path).appendingPathComponent(rel)
                appendVerdict(url, ignored: true, owner: r.id, to: &candidates)
            }
        }

        // 3) Size + threshold, publishing incrementally: already-cached sizes
        // appear at once, the rest as each bounded-parallel `du` completes.
        // Cancellation (stopMapBuild / a newer scan) is honored between sizes.
        let autoFloor: UInt64 = 50 * 1024 * 1024
        let showFloor: UInt64 = 200 * 1024 * 1024

        func appendItem(_ c: JunkCandidate, size: UInt64) {
            let floor = c.auto ? autoFloor : showFloor
            guard size >= floor else { return }
            // Avoid double-counting: shrink the owning repo's green block.
            if let owner = c.ownerRepoID, let gi = items.firstIndex(where: { $0.id == owner }) {
                items[gi].bytes = items[gi].bytes > size ? items[gi].bytes - size : 0
            }
            items.append(MapItem(id: c.url.path, name: junkDisplayName(c.url), path: c.url.path,
                                 bytes: size, kind: c.auto ? .junkAuto : .junkShowOnly,
                                 subtitle: PathDisplay.tilde(c.url.path),
                                 badge: NSLocalizedString(c.auto ? "map.badge.clearable" : "map.badge.regen", comment: ""),
                                 reason: c.auto ? nil : NSLocalizedString("map.reason.showonly", comment: "")))
        }

        var unsized: [JunkCandidate] = []
        for c in candidates {
            if let cached = sizeCache[c.url.path] { appendItem(c, size: cached) } else { unsized.append(c) }
        }
        mapItems = items.sorted { $0.bytes > $1.bytes }

        await withTaskGroup(of: (Int, UInt64).self) { group in
            var next = 0
            func addNext() {
                guard next < unsized.count, !Task.isCancelled else { return }
                let index = next
                let path = unsized[index].url.path
                next += 1
                group.addTask { (index, await DiskUsage.bytes(atPath: path)) }
            }
            for _ in 0..<4 { addNext() }
            for await (index, size) in group {
                if Task.isCancelled || gen != scanGeneration { group.cancelAll(); return }
                let c = unsized[index]
                sizeCache[c.url.path] = size
                appendItem(c, size: size)
                mapItems = items.sorted { $0.bytes > $1.bytes }
                addNext()
            }
        }
    }

    /// Disambiguate generically-named junk by including its parent folder, so a
    /// bare "caches" reads as ".gradle/caches" and is never confused with another
    /// folder that merely shares the name.
    private func junkDisplayName(_ url: URL) -> String {
        let name = url.lastPathComponent
        let generic: Set<String> = ["caches", "cache", "Caches", "build", "dist",
                                    "out", "bin", "obj", "target", "tmp", "temp", "data"]
        guard generic.contains(name) else { return name }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? name : "\(parent)/\(name)"
    }

    private func appendVerdict(_ url: URL, ignored: Bool, owner: String?, to candidates: inout [JunkCandidate]) {
        let inICloud = url.path.contains("Mobile Documents")
        switch JunkClassifier.verdict(for: url, gitIgnored: ignored, gitTracked: false, inICloud: inICloud) {
        case .autoDeletable: candidates.append(JunkCandidate(url: url, auto: true, ownerRepoID: owner))
        case .showOnly:      candidates.append(JunkCandidate(url: url, auto: false, ownerRepoID: owner))
        case .notJunk:       break
        }
    }

    /// One-click junk deletion. ALWAYS to Trash (recoverable) — deliberately
    /// ignores OffloadSettings.permanentDelete, which only governs verified offload.
    func trashJunk(_ item: MapItem) async {
        guard item.kind == .junkAuto else { return }
        let url = URL(fileURLWithPath: item.path)
        guard PathSafety.isSafeToDelete(url) else {
            lastError = NSLocalizedString("offload.error.protected_path", comment: "")
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            }.value
            sessionReclaimed += item.bytes
            sizeCache.removeValue(forKey: item.path)
            mapItems.removeAll { $0.id == item.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restore(_ m: OffloadManifest) async {
        guard phase == .idle else { return }
        phase = .restoring(repo: m.projectName)
        defer { phase = .idle }
        let dir = URL(fileURLWithPath: m.originalPath)
        let parent = dir.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".cacheclear-restore-\(m.projectName)-\(UUID().uuidString.prefix(6))")

        /// Only restore over a directory that holds nothing but our stub. Checked
        /// once before the (slow, networked) clone AND once right before the
        /// swap — anything saved into the stub folder during the clone must not
        /// be deleted.
        func holdsOnlyStub() -> Bool {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            return contents.allSatisfy {
                $0 == OffloadManifest.stubFileName || $0 == OffloadManifest.readmeFileName || $0 == ".DS_Store"
            }
        }

        do {
            guard holdsOnlyStub() else { throw OffloadError.restoreCollision }
            guard PathSafety.isSafeToDelete(dir) else { throw OffloadError.restoreCollision }

            try await runner.gitChecked(["clone", m.remoteURL, temp.path], in: parent, network: true)
            if !m.defaultBranch.isEmpty {
                _ = try? await runner.git(["checkout", m.defaultBranch], in: temp)
            }

            guard holdsOnlyStub() else { throw OffloadError.restoreCollision }
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: dir)
                try FileManager.default.moveItem(at: temp, to: dir)
            }.value

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

    /// Menu bar → "Restore": bring the window to the Restore tab with a fresh list.
    func requestRestoreTab() {
        restoreTabRequests += 1
        Task { await refreshOffloads() }
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
}
