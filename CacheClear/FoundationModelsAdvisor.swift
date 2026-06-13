//
//  FoundationModelsAdvisor.swift
//  CacheClear
//
//  On-device Apple Intelligence advisor (macOS 26+). This is the ONLY file that
//  imports FoundationModels. It wraps the deterministic RuleBasedOffloadAdvisor:
//  the rule engine decides what is allowed; the model only rewrites the
//  explanation in friendlier language and may ask one clarifying question. It
//  can never turn a block into a green-light.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct GeneratedAdvice {
    @Guide(description: "Exactly one of: safeToOffload, pushThenOffload, resolveFirst, doNotOffload")
    var recommendation: String

    @Guide(description: "A short headline in Traditional Chinese, at most 16 characters")
    var headline: String

    @Guide(description: "A plain-language explanation in Traditional Chinese, 1 to 3 sentences, for a developer who is not a git expert")
    var explanation: String

    @Guide(description: "Up to 4 short, concrete next-step instructions in Traditional Chinese")
    var steps: [String]

    @Guide(description: "A single clarifying question in Traditional Chinese if the situation is ambiguous, otherwise an empty string")
    var clarifyingQuestion: String
}

@available(macOS 26.0, *)
struct FoundationModelsAdvisor: OffloadAdvisor {

    private let floor = RuleBasedOffloadAdvisor()

    static func isSupported() -> Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    private static let instructions = """
    你是 CacheClear App 內的「卸載協調助理」,協助使用者把本機的 Git 專案安全地推送到 \
    GitHub 後,釋放本機磁碟空間。你的最高原則:除非 GitHub 已經(或即將透過自動推送)\
    確實擁有全部內容,否則絕不建議刪除本機程式碼。當情況不明確時,寧可提出「一個」釐清問題,\
    也不要猜測。一律使用繁體中文,語氣冷靜、具體、像資深工程師在旁邊協助。你只負責「解釋與建議」,\
    實際的刪除與否一律由 App 的安全規則決定。
    """

    func advise(_ context: RepoAdviceContext) async -> OffloadAdvice {
        let ruleAdvice = floor.evaluate(context)
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: prompt(for: context, floor: ruleAdvice),
                                                     generating: GeneratedAdvice.self)
            return merge(generated: response.content, floor: ruleAdvice)
        } catch {
            // Any model error → fall back silently to the deterministic advice.
            return ruleAdvice
        }
    }

    private func prompt(for c: RepoAdviceContext, floor: OffloadAdvice) -> String {
        var lines: [String] = []
        lines.append("專案名稱: \(c.name)")
        lines.append("是否有遠端: \(c.hasRemote ? "有" : "無")"
            + (c.hasRemote ? "(GitHub: \(c.remoteIsGitHub ? "是" : "否")" + (c.remoteIsPrivate.map { ", 私有: \($0 ? "是" : "否")" } ?? "") + ")" : ""))
        lines.append("預設分支: \(c.defaultBranch.isEmpty ? "(無提交)" : c.defaultBranch)")
        if let age = c.ageDays { lines.append("閒置天數: \(age)") }
        lines.append("專案大小: \(c.humanSize)")
        lines.append("未推送的 ref 數量: \(c.unpushedRefCount)")
        lines.append("已修改但未提交的追蹤檔案數量: \(c.dirtyTrackedCount)")
        lines.append("與遠端是否分歧: \(c.diverged ? "是(有真正的合併衝突風險)" : "否")")
        if !c.untrackedFileNames.isEmpty { lines.append("未追蹤檔名: \(c.untrackedFileNames.prefix(20).joined(separator: ", "))") }
        if !c.ignoredSecretNames.isEmpty { lines.append("被忽略且疑似機密的檔名: \(c.ignoredSecretNames.joined(separator: ", "))") }
        if !c.ignoredDataNames.isEmpty { lines.append("被忽略且疑似資料的檔名: \(c.ignoredDataNames.joined(separator: ", "))") }
        if !c.regenerableNames.isEmpty { lines.append("可重新產生而會被丟棄的目錄: \(c.regenerableNames.prefix(10).joined(separator: ", "))") }
        if c.isDetachedHead { lines.append("處於 detached HEAD 狀態") }
        if c.submodulesPresent { lines.append("包含 submodule") }
        if c.lfsPresent { lines.append("使用 Git LFS" + (c.lfsToolMissing ? "(但本機未安裝 git-lfs)" : "")) }
        if !c.largeBlobs.isEmpty { lines.append("超大檔案: \(c.largeBlobs.prefix(5).joined(separator: ", "))") }
        if let mid = c.midOperation { lines.append("正在進行中的 git 操作: \(mid.rawValue)") }

        let context = lines.joined(separator: "\n")
        return """
        以下是某個本機 Git 專案的狀態(只有檔名與中繼資料,沒有任何檔案內容):
        \(context)

        App 的安全規則已先行判定(這是你不可推翻的底線):
        - 建議結果: \(floor.recommendation.rawValue)
        - 原因: \(floor.headline)

        請根據以上資訊,用更貼近一般開發者的語言重新說明這個狀況,並給出建議。
        你給出的 recommendation 安全程度不得低於上面的底線(例如底線是 doNotOffload 或 \
        resolveFirst,你就不能改成 safeToOffload)。若有需要,提出一個釐清問題。
        """
    }

    private func merge(generated g: GeneratedAdvice, floor: OffloadAdvice) -> OffloadAdvice {
        let modelRec = AdviceRecommendation(rawValue: g.recommendation) ?? floor.recommendation
        // Clamp: the model may only be equally or MORE cautious than the rules.
        let recommendation = modelRec.rank >= floor.recommendation.rank ? modelRec : floor.recommendation
        let headline = g.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = g.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = g.clarifyingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return OffloadAdvice(
            recommendation: recommendation,
            severity: floor.severity,                 // keep deterministic severity
            headline: headline.isEmpty ? floor.headline : headline,
            explanation: explanation.isEmpty ? floor.explanation : explanation,
            steps: g.steps.isEmpty ? floor.steps : g.steps,
            options: floor.options,                   // actions stay deterministic
            clarifyingQuestion: question.isEmpty ? floor.clarifyingQuestion : question,
            fromModel: true)
    }
}
#endif
