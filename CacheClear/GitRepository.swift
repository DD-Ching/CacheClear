//
//  GitRepository.swift
//  CacheClear
//
//  Value models for the GitHub Offload & Reclaim feature.
//

import Foundation

/// High-level safety classification for a project repo. Drives the badge, the
/// auto-select rules and — most importantly — whether the destructive "reclaim"
/// step is allowed to run at all.
enum SafetyStatus: String, Codable {
    /// Clean working tree, everything already on the remote. Reclaim immediately.
    case safeToOffload
    /// Local commits / uncommitted tracked work that the pipeline will snapshot
    /// and push automatically before reclaiming.
    case needsPushFirst
    /// Untracked or gitignored files that look like secrets/data (.env, *.key,
    /// *.sqlite). Routed to the coordination manager; reclaim is blocked.
    case hasLocalOnlySecrets
    /// Local and remote have diverged — a real merge conflict. Manager only.
    case conflictRisk
    /// No git remote at all. Eligible only after creating a private repo.
    case noRemote
    /// Mid-rebase/merge, LFS without git-lfs, oversized blob, submodules, …
    /// Hard block: never offloaded or deleted.
    case blocked
    case unknown

    /// Whether a repo in this state may be auto-selected by the inactive-days rule.
    var isAutoSelectable: Bool {
        switch self {
        case .safeToOffload, .needsPushFirst: return true
        default: return false
        }
    }

    /// Whether the user may manually tick this repo for offload (it still has to
    /// pass the live verification gate before anything is deleted).
    var isManuallySelectable: Bool {
        switch self {
        case .safeToOffload, .needsPushFirst, .noRemote: return true
        case .hasLocalOnlySecrets, .conflictRisk, .blocked, .unknown: return false
        }
    }
}

enum MidOpKind: String, Codable {
    case merge, rebase, cherryPick, revert, bisect
}

/// Result of the network pre-flight that confirms, BEFORE the user commits to an
/// offload, that a repo's push target is reachable and the push would actually
/// go through (fast-forward). This is the extra layer of assurance on top of the
/// local classification.
enum PreflightStatus: Hashable {
    case notChecked
    case checking
    case confirmed        // remote reachable + auth ok + fast-forwardable
    case willCreateRepo   // no remote yet; a private repo will be created
    case problem(String)  // behind/diverged/unreachable — excluded from auto-select
}

/// An untracked-but-ignored file that a plain `git push` would NOT carry to the
/// remote, classified so the pipeline knows whether deleting it loses anything.
struct IgnoredFile: Hashable, Codable {
    enum Kind: String, Codable {
        case secret       // .env, *.pem, *.key, credentials — block reclaim
        case data         // *.sqlite, *.db, *.dump — block reclaim
        case regenerable  // node_modules, build/, Pods — safe to drop
        case other        // anything else ignored — warn loudly
    }
    let path: String
    let kind: Kind
}

struct RepoSafetyReport: Codable, Hashable {
    var status: SafetyStatus = .unknown
    var hasRemote = false
    var remoteIsGitHub = false
    var remoteIsPrivate: Bool?
    var defaultBranch = ""
    var isDetachedHead = false
    var isEmptyRepo = false
    var dirtyTrackedCount = 0
    var untrackedFiles: [String] = []
    var ignoredFiles: [IgnoredFile] = []
    var unpushedRefCount = 0
    var diverged = false
    var stashCount = 0
    var midOperation: MidOpKind?
    var submodulesPresent = false
    var lfsPresent = false
    var lfsToolMissing = false
    var largeBlobs: [String] = []
    /// Committed mode-160000 gitlinks under .claude/worktrees — stray Claude Code
    /// agent worktrees. They keep `git status` perpetually dirty; the pipeline
    /// untracks + gitignores them so the tree can verify clean. Regenerable.
    var strayWorktrees: [String] = []
    /// Other unregistered gitlinks (no .gitmodules) — unknown nested repos that
    /// may hold real work, so they BLOCK offload rather than being auto-cleaned.
    var unregisteredGitlinks: [String] = []
    var blockingReasons: [String] = []
    var warnings: [String] = []

    var secretOrDataIgnored: [IgnoredFile] {
        ignoredFiles.filter { $0.kind == .secret || $0.kind == .data }
    }
    var regenerableIgnored: [IgnoredFile] {
        ignoredFiles.filter { $0.kind == .regenerable }
    }
    /// Untracked-not-ignored + "other" ignored files: not secrets, but still get
    /// surfaced in the confirm dialog because dropping them is not free.
    var atRiskOtherFiles: [String] {
        untrackedFiles + ignoredFiles.filter { $0.kind == .other }.map(\.path)
    }
}

struct ProjectRepo: Identifiable, Hashable {
    let id: String        // canonical worktree top-level path (stable identity)
    var name: String      // last path component
    var path: String      // worktree top-level
    var relativePath: String
    var remoteURL: String?
    var lastActivity: Date?
    var sizeBytes: UInt64
    var report: RepoSafetyReport
    var isSelected: Bool = false
    var preflight: PreflightStatus = .notChecked

    var ageDays: Int? {
        guard let last = lastActivity else { return nil }
        return Calendar.current.dateComponents([.day], from: last, to: Date()).day
    }

    /// GitHub "owner/name" slug if the remote points at github.com, else nil.
    var githubSlug: String? {
        guard let remote = remoteURL else { return nil }
        return ProjectRepo.parseGitHubSlug(remote)
    }

    static func parseGitHubSlug(_ url: String) -> String? {
        // Handles https://github.com/owner/repo(.git) and git@github.com:owner/repo(.git)
        var s = url
        if let range = s.range(of: "github.com") {
            s = String(s[range.upperBound...])
        } else {
            return nil
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

// MARK: - Restore manifest (the stub left behind in place of the reclaimed repo)

struct VaultedSecret: Codable, Hashable {
    let relativePath: String
    let vaultPath: String
}

struct OffloadManifest: Codable, Identifiable, Hashable {
    var schemaVersion = 1
    var projectName: String
    var originalPath: String
    var remoteURL: String
    var sshURL: String?
    var defaultBranch: String
    var headSHA: String
    var pushedRefs: [String: String]
    var repoVisibility: String?
    var reclaimedBytes: UInt64
    var deletionMode: String           // "trash" | "permanent"
    var offloadedAt: Date
    var appVersion: String
    var verifiedRemote: Bool
    var backedUpSecrets: [VaultedSecret]

    var id: String { originalPath }

    /// True when the directory at `originalPath` currently holds only the stub
    /// (i.e. the project really is offloaded and can be restored).
    var isStillOffloaded: Bool {
        OffloadManifest.stubExists(at: originalPath)
    }

    static let stubFileName = ".cacheclear-offload.json"
    static let readmeFileName = "README.RESTORE.md"

    static func stubExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(stubFileName))
    }
}
