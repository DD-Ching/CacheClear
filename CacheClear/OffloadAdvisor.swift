//
//  OffloadAdvisor.swift
//  CacheClear
//
//  The "coordination manager" abstraction. A deterministic rule-based advisor is
//  ALWAYS the source of truth for whether a repo may be reclaimed; the optional
//  on-device Foundation Models advisor (see FoundationModelsAdvisor.swift) may
//  only add explanation and never downgrade a block.
//

import Foundation

enum AdviceRecommendation: String, Codable, Sendable {
    case safeToOffload     // green-light
    case pushThenOffload   // auto-handled, informational
    case resolveFirst      // needs a user decision (secrets / divergence)
    case doNotOffload      // hard block

    /// Lower is safer-to-act; used to clamp an over-optimistic LLM.
    var rank: Int {
        switch self {
        case .safeToOffload: return 0
        case .pushThenOffload: return 1
        case .resolveFirst: return 2
        case .doNotOffload: return 3
        }
    }
}

enum AdviceSeverity: String, Codable, Sendable { case info, warning, blocking }

/// A single choice the manager can offer the user. `key` maps to a deterministic
/// action in OffloadManager; the LLM only ever picks wording/ordering.
struct AdviceOption: Codable, Sendable, Hashable, Identifiable {
    enum Action: String, Codable, Sendable {
        case proceed          // proceed with offload as-is
        case createPrivateRepo
        case skipRepo
        case revealInFinder    // let the user fix it manually
        case openTerminalHint  // show the exact git command to run
        case cancel
    }
    var id: String { key }
    let key: String
    let label: String
    let action: Action
}

struct OffloadAdvice: Codable, Sendable, Hashable {
    let recommendation: AdviceRecommendation
    let severity: AdviceSeverity
    let headline: String
    let explanation: String
    let steps: [String]
    let options: [AdviceOption]
    let clarifyingQuestion: String?
    /// True when produced by the on-device model rather than the rule engine.
    var fromModel: Bool = false
}

/// Privacy-safe context handed to any advisor: metadata and file *names* only —
/// never file contents or secret values.
struct RepoAdviceContext: Sendable {
    let name: String
    let hasRemote: Bool
    let remoteIsGitHub: Bool
    let remoteIsPrivate: Bool?
    let defaultBranch: String
    let ageDays: Int?
    let humanSize: String
    let status: SafetyStatus
    let dirtyTrackedCount: Int
    let unpushedRefCount: Int
    let diverged: Bool
    let untrackedFileNames: [String]
    let ignoredSecretNames: [String]
    let ignoredDataNames: [String]
    let regenerableNames: [String]
    let isDetachedHead: Bool
    let submodulesPresent: Bool
    let lfsPresent: Bool
    let lfsToolMissing: Bool
    let largeBlobs: [String]
    let midOperation: MidOpKind?
    let blockingReasons: [String]

    init(repo: ProjectRepo, humanSize: String) {
        let r = repo.report
        name = repo.name
        hasRemote = r.hasRemote
        remoteIsGitHub = r.remoteIsGitHub
        remoteIsPrivate = r.remoteIsPrivate
        defaultBranch = r.defaultBranch
        ageDays = repo.ageDays
        self.humanSize = humanSize
        status = r.status
        dirtyTrackedCount = r.dirtyTrackedCount
        unpushedRefCount = r.unpushedRefCount
        diverged = r.diverged
        untrackedFileNames = r.untrackedFiles
        ignoredSecretNames = r.ignoredFiles.filter { $0.kind == .secret }.map(\.path)
        ignoredDataNames = r.ignoredFiles.filter { $0.kind == .data }.map(\.path)
        regenerableNames = r.regenerableIgnored.map(\.path)
        isDetachedHead = r.isDetachedHead
        submodulesPresent = r.submodulesPresent
        lfsPresent = r.lfsPresent
        lfsToolMissing = r.lfsToolMissing
        largeBlobs = r.largeBlobs
        midOperation = r.midOperation
        blockingReasons = r.blockingReasons
    }
}

protocol OffloadAdvisor: Sendable {
    func advise(_ context: RepoAdviceContext) async -> OffloadAdvice
}

// MARK: - Deterministic rule engine (the safety floor)

struct RuleBasedOffloadAdvisor: OffloadAdvisor {

    func advise(_ context: RepoAdviceContext) async -> OffloadAdvice {
        evaluate(context)
    }

    /// Pure, synchronous evaluation. Also used by FoundationModelsAdvisor as the
    /// clamp the LLM cannot escape.
    func evaluate(_ c: RepoAdviceContext) -> OffloadAdvice {
        func L(_ key: String, _ args: CVarArg...) -> String {
            let fmt = NSLocalizedString(key, comment: "")
            return args.isEmpty ? fmt : String(format: fmt, arguments: args)
        }

        let proceed = AdviceOption(key: "proceed", label: L("manager.option.proceed"), action: .proceed)
        let skip = AdviceOption(key: "skip", label: L("manager.option.skip"), action: .skipRepo)
        let reveal = AdviceOption(key: "reveal", label: L("manager.option.reveal"), action: .revealInFinder)
        let cancel = AdviceOption(key: "cancel", label: L("manager.option.cancel"), action: .cancel)

        // --- Hard blocks ---------------------------------------------------
        if let mid = c.midOperation {
            return OffloadAdvice(
                recommendation: .doNotOffload, severity: .blocking,
                headline: L("manager.block.midop.headline"),
                explanation: L("manager.block.midop.body", mid.rawValue),
                steps: ["git -C \"\(c.name)\" status", "git rebase --abort  /  git merge --abort"],
                options: [reveal, skip, cancel], clarifyingQuestion: nil)
        }
        if c.lfsPresent && c.lfsToolMissing {
            return OffloadAdvice(
                recommendation: .doNotOffload, severity: .blocking,
                headline: L("manager.block.lfs.headline"),
                explanation: L("manager.block.lfs.body"),
                steps: ["brew install git-lfs", "git lfs install", "git lfs push --all origin"],
                options: [reveal, skip, cancel], clarifyingQuestion: nil)
        }
        if !c.largeBlobs.isEmpty {
            return OffloadAdvice(
                recommendation: .doNotOffload, severity: .blocking,
                headline: L("manager.block.large.headline"),
                explanation: L("manager.block.large.body", c.largeBlobs.prefix(3).joined(separator: ", ")),
                steps: ["git lfs track \"<big file>\"", "或將大檔移出 repo 後再卸載"],
                options: [reveal, skip, cancel], clarifyingQuestion: nil)
        }
        if c.submodulesPresent {
            return OffloadAdvice(
                recommendation: .doNotOffload, severity: .blocking,
                headline: L("manager.block.submodule.headline"),
                explanation: L("manager.block.submodule.body"),
                steps: ["先個別將每個 submodule 推送到它自己的遠端"],
                options: [reveal, skip, cancel], clarifyingQuestion: nil)
        }

        // --- Needs a decision ---------------------------------------------
        if c.diverged {
            return OffloadAdvice(
                recommendation: .resolveFirst, severity: .blocking,
                headline: L("manager.conflict.diverged.headline"),
                explanation: L("manager.conflict.diverged.body"),
                steps: ["git pull --rebase origin \(c.defaultBranch)", "解決衝突後再卸載"],
                options: [reveal, skip, cancel],
                clarifyingQuestion: L("manager.conflict.diverged.question"))
        }
        let secrets = c.ignoredSecretNames + c.ignoredDataNames
        if !secrets.isEmpty {
            return OffloadAdvice(
                recommendation: .resolveFirst, severity: .blocking,
                headline: L("manager.secret.headline"),
                explanation: L("manager.secret.body", secrets.prefix(5).joined(separator: ", ")),
                steps: [
                    L("manager.secret.step_keep"),
                    L("manager.secret.step_commit"),
                ],
                options: [reveal, skip, cancel],
                clarifyingQuestion: L("manager.secret.question"))
        }

        // --- No remote ------------------------------------------------------
        if !c.hasRemote {
            let create = AdviceOption(key: "create", label: L("manager.option.create_private"), action: .createPrivateRepo)
            return OffloadAdvice(
                recommendation: .resolveFirst, severity: .warning,
                headline: L("manager.no_remote.headline"),
                explanation: L("manager.no_remote.body", c.name),
                steps: ["gh repo create \(c.name) --private --source . --push"],
                options: [create, skip, cancel],
                clarifyingQuestion: L("manager.no_remote.question"))
        }

        // --- Auto-handled push ---------------------------------------------
        if c.unpushedRefCount > 0 || c.dirtyTrackedCount > 0 {
            return OffloadAdvice(
                recommendation: .pushThenOffload, severity: .info,
                headline: L("manager.push.headline"),
                explanation: L("manager.push.body", c.dirtyTrackedCount, c.unpushedRefCount),
                steps: ["git add -A && git commit", "git push --all && git push --tags"],
                options: [proceed, skip, cancel], clarifyingQuestion: nil)
        }

        // --- All clear ------------------------------------------------------
        return OffloadAdvice(
            recommendation: .safeToOffload, severity: .info,
            headline: L("manager.safe.headline"),
            explanation: L("manager.safe.body"),
            steps: [], options: [proceed, skip, cancel], clarifyingQuestion: nil)
    }
}

// MARK: - Factory

enum AdvisorFactory {
    /// Returns the on-device model advisor when macOS 26 + Apple Intelligence are
    /// ready, otherwise the deterministic rule engine.
    static func make() -> OffloadAdvisor {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), FoundationModelsAdvisor.isSupported() {
            return FoundationModelsAdvisor()
        }
        #endif
        return RuleBasedOffloadAdvisor()
    }

    static var isModelBacked: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsAdvisor.isSupported() }
        #endif
        return false
    }
}
