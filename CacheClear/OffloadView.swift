//
//  OffloadView.swift
//  CacheClear
//
//  The GitHub Offload & Reclaim hub: review repos and their safety status, talk
//  to the coordination manager about anything risky, push & reclaim behind a
//  two-gate confirmation, and restore offloaded projects.
//

import SwiftUI
import AppKit

struct OffloadView: View {
    @ObservedObject private var manager = OffloadManager.shared
    @ObservedObject private var settings = OffloadSettings.shared

    @State private var mode: Mode = .offload
    @State private var expanded: Set<String> = []
    @State private var adviceRepo: ProjectRepo?

    enum Mode: String, CaseIterable, Identifiable {
        case offload, restore
        var id: String { rawValue }
        var titleKey: String { self == .offload ? "offload.mode.offload" : "offload.mode.restore" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            Group {
                if mode == .offload { offloadPane } else { restorePane }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay { if manager.isBusy { busyOverlay } }
        .sheet(item: $adviceRepo) { repo in
            AdviceSheet(repo: repo) { action in handle(action, for: repo) }
        }
        .onAppear { if mode == .restore { Task { await manager.refreshOffloads() } } }
    }

    // MARK: - Offload pane

    private var offloadPane: some View {
        VStack(spacing: 0) {
            offloadHeader
            if !manager.repos.isEmpty { planBanner }
            Divider()
            if manager.repos.isEmpty {
                emptyState(manager.rootURL == nil ? "offload.empty.no_root" : "offload.empty.no_repos")
            } else {
                ScrollView { LazyVStack(spacing: 0) { ForEach(manager.repos) { repoRow($0) } } }
            }
            Divider()
            offloadFooter
        }
    }

    private var offloadHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("offload.root_label")).font(.caption).foregroundColor(.secondary)
                Text(manager.rootURL?.path ?? NSLocalizedString("offload.root_unset", comment: ""))
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Button(LocalizedStringKey("offload.choose_root")) { chooseRoot() }
                    Button(LocalizedStringKey("offload.rescan")) { Task { await manager.scan() } }
                        .disabled(manager.rootURL == nil || manager.isBusy)
                    if !manager.statusLine.isEmpty {
                        ProgressView().controlSize(.small)
                        Text(manager.statusLine).font(.caption).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 1) {
                Text(LocalizedStringKey("offload.reclaim_space_label")).font(.caption).foregroundColor(.secondary)
                Text(OffloadManager.formatBytes(manager.reclaimableBytes))
                    .font(.system(size: 24, weight: .semibold)).foregroundColor(.accentColor)
                Text(String(format: NSLocalizedString("offload.selected_count_format", comment: ""),
                            manager.selectedRepos.count))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    private var planBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("offload.banner_format", comment: ""),
                            manager.eligibleCount, manager.confirmedCount))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(LocalizedStringKey("offload.select_all")) { manager.selectAllEligible() }
                .disabled(manager.isBusy)
            Button(LocalizedStringKey("offload.deselect_all")) { manager.deselectAll() }
                .disabled(manager.isBusy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    private var offloadFooter: some View {
        HStack {
            Text(String(format: NSLocalizedString("offload.summary_format", comment: ""),
                        manager.selectedRepos.count,
                        OffloadManager.formatBytes(manager.reclaimableBytes)))
                .font(.callout)
            Spacer()
            Button(role: .destructive) { confirmAndOffload() } label: {
                Label(LocalizedStringKey("offload.push_button"), systemImage: "externaldrive.badge.checkmark")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(manager.selectedRepos.isEmpty || manager.isBusy)
        }
        .padding(12)
    }

    private func repoRow(_ repo: ProjectRepo) -> some View {
        let result = manager.results[repo.id]
        let isExpanded = expanded.contains(repo.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                selectionBox(repo, done: result != nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.name).fontWeight(.medium)
                        if let slug = repo.githubSlug {
                            Text(slug).font(.caption).foregroundColor(.secondary)
                        } else {
                            Text(LocalizedStringKey("offload.no_remote_pill")).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2)).cornerRadius(4)
                        }
                    }
                    Text(ageText(repo)).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if let result {
                    resultBadge(result)
                } else {
                    preflightBadge(repo.preflight)
                    statusBadge(repo.report.status)
                }
                Text(OffloadManager.formatBytes(repo.sizeBytes))
                    .font(.callout).foregroundColor(.secondary)
                    .frame(width: 72, alignment: .trailing)
                Button { toggleExpand(repo.id) } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if isExpanded { repoDetail(repo).padding(.horizontal, 12).padding(.bottom, 10) }
            Divider()
        }
    }

    private func selectionBox(_ repo: ProjectRepo, done: Bool) -> some View {
        Group {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if repo.report.status.isManuallySelectable {
                Button { manager.toggle(repo.id) } label: {
                    Image(systemName: repo.isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(repo.isSelected ? .accentColor : .secondary)
                }.buttonStyle(.borderless)
            } else {
                Image(systemName: "square.slash").foregroundColor(.secondary.opacity(0.5))
            }
        }
        .frame(width: 22)
    }

    @ViewBuilder
    private func repoDetail(_ repo: ProjectRepo) -> some View {
        let r = repo.report
        VStack(alignment: .leading, spacing: 8) {
            detailGroup("offload.group.will_push", color: .blue, items: willPushItems(r))
            if !r.regenerableIgnored.isEmpty {
                detailGroup("offload.group.will_reclaim", color: .secondary, items: r.regenerableIgnored.map(\.path))
            }
            let lose = r.secretOrDataIgnored.map(\.path) + r.atRiskOtherFiles
            if !lose.isEmpty {
                detailGroup("offload.group.will_lose", color: .red, items: lose)
            }
            if !repo.report.status.isAutoSelectable {
                Button { adviceRepo = repo } label: {
                    Label(LocalizedStringKey("offload.ask_assistant"), systemImage: "wand.and.stars")
                }.buttonStyle(.borderless).padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func willPushItems(_ r: RepoSafetyReport) -> [String] {
        var items: [String] = []
        if r.unpushedRefCount > 0 {
            items.append(String(format: NSLocalizedString("offload.detail.unpushed_format", comment: ""), r.unpushedRefCount))
        }
        if r.dirtyTrackedCount > 0 {
            items.append(String(format: NSLocalizedString("offload.detail.dirty_format", comment: ""), r.dirtyTrackedCount))
        }
        items.append(contentsOf: r.untrackedFiles.prefix(20))
        if items.isEmpty { items.append(NSLocalizedString("offload.detail.all_pushed", comment: "")) }
        return items
    }

    private func detailGroup(_ titleKey: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(titleKey)).font(.caption).fontWeight(.semibold).foregroundColor(color)
            ForEach(Array(items.prefix(30).enumerated()), id: \.offset) { _, item in
                Text("• \(item)").font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: - Restore pane

    private var restorePane: some View {
        Group {
            if manager.offloads.isEmpty {
                emptyState("restore.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.offloads) { m in restoreRow(m) }
                    }
                }
            }
        }
    }

    private func restoreRow(_ m: OffloadManifest) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.checkmark").foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.projectName).fontWeight(.medium)
                    Text(m.remoteURL).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(OffloadManager.formatBytes(m.reclaimedBytes)).font(.caption).foregroundColor(.secondary)
                Button(LocalizedStringKey("restore.button")) { Task { await manager.restore(m) } }
                    .disabled(manager.isBusy)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
        }
    }

    // MARK: - Shared

    private func emptyState(_ key: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundColor(.secondary)
            Text(LocalizedStringKey(key)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text(phaseText).font(.callout)
                if !manager.statusLine.isEmpty { Text(manager.statusLine).font(.caption).foregroundColor(.secondary) }
            }
            .padding(24)
            .background(.regularMaterial)
            .cornerRadius(12)
        }
    }

    private var phaseText: String {
        switch manager.phase {
        case .idle: return ""
        case .scanning: return NSLocalizedString("offload.phase.scanning", comment: "")
        case .restoring(let r): return String(format: NSLocalizedString("offload.phase.restoring", comment: ""), r)
        case .offloading(let r, let step):
            return String(format: NSLocalizedString("offload.phase.offloading", comment: ""),
                          r, NSLocalizedString(step.labelKey, comment: ""))
        }
    }

    private func statusBadge(_ status: SafetyStatus) -> some View {
        let (key, color): (String, Color) = {
            switch status {
            case .safeToOffload: return ("offload.status.safe", .green)
            case .needsPushFirst: return ("offload.status.push", .blue)
            case .noRemote: return ("offload.status.no_remote", .orange)
            case .hasLocalOnlySecrets: return ("offload.status.secrets", .red)
            case .conflictRisk: return ("offload.status.conflict", .purple)
            case .blocked: return ("offload.status.blocked", .red)
            case .unknown: return ("offload.status.unknown", .gray)
            }
        }()
        return Text(LocalizedStringKey(key))
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18)).foregroundColor(color).cornerRadius(5)
    }

    @ViewBuilder
    private func preflightBadge(_ p: PreflightStatus) -> some View {
        switch p {
        case .confirmed:
            Label(LocalizedStringKey("offload.preflight.confirmed"), systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon).font(.caption2).foregroundColor(.green)
        case .willCreateRepo:
            Label(LocalizedStringKey("offload.preflight.will_create"), systemImage: "plus.circle")
                .labelStyle(.titleAndIcon).font(.caption2).foregroundColor(.orange)
        case .checking:
            HStack(spacing: 3) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey("offload.preflight.checking")).font(.caption2).foregroundColor(.secondary)
            }
        case .notChecked, .problem:
            EmptyView()
        }
    }

    private func resultBadge(_ result: RepoResult) -> some View {
        Text(result.state == .offloaded
             ? NSLocalizedString("offload.result.done", comment: "")
             : result.message)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((result.state == .offloaded ? Color.green : Color.red).opacity(0.18))
            .foregroundColor(result.state == .offloaded ? .green : .red)
            .cornerRadius(5).lineLimit(1)
    }

    private func ageText(_ repo: ProjectRepo) -> String {
        guard let days = repo.ageDays else { return NSLocalizedString("offload.age.unknown", comment: "") }
        return String(format: NSLocalizedString("offload.age.days_format", comment: ""), days)
    }

    // MARK: - Actions

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = NSLocalizedString("offload.choose_root_title", comment: "")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            manager.setRoot(url)
        }
    }

    private func handle(_ action: AdviceOption.Action, for repo: ProjectRepo) {
        switch action {
        case .proceed, .createPrivateRepo:
            if let i = manager.repos.firstIndex(where: { $0.id == repo.id }),
               manager.repos[i].report.status.isManuallySelectable,
               !manager.repos[i].isSelected {
                manager.toggle(repo.id)
            }
        case .skipRepo:
            if let i = manager.repos.firstIndex(where: { $0.id == repo.id }), manager.repos[i].isSelected {
                manager.toggle(repo.id)
            }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
        case .openTerminalHint, .cancel:
            break
        }
    }

    private func confirmAndOffload() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString("offload.confirm.title", comment: "")
        alert.informativeText = String(format: NSLocalizedString("offload.confirm.message", comment: ""),
                                       manager.selectedRepos.count,
                                       OffloadManager.formatBytes(manager.reclaimableBytes))
        let confirm = alert.addButton(withTitle: NSLocalizedString("offload.confirm.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("offload.confirm.cancel", comment: ""))
        confirm.hasDestructiveAction = true
        confirm.isEnabled = false

        let checkbox = NSButton(checkboxWithTitle: NSLocalizedString("offload.confirm.checkbox", comment: ""),
                                target: nil, action: nil)
        let gate = ConfirmGate()
        gate.confirmButton = confirm
        checkbox.target = gate
        checkbox.action = #selector(ConfirmGate.toggle(_:))
        checkbox.state = .off
        alert.accessoryView = checkbox

        if alert.runModal() == .alertFirstButtonReturn {
            Task { await manager.offloadSelected() }
        }
    }
}

/// Keeps the destructive button disabled until the acknowledgement box is ticked.
final class ConfirmGate: NSObject {
    weak var confirmButton: NSButton?
    @objc func toggle(_ sender: NSButton) {
        confirmButton?.isEnabled = (sender.state == .on)
    }
}

// MARK: - Advice (coordination manager) sheet

struct AdviceSheet: View {
    let repo: ProjectRepo
    var onResolve: (AdviceOption.Action) -> Void

    @ObservedObject private var manager = OffloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var advice: OffloadAdvice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundColor(.accentColor)
                Text(LocalizedStringKey("manager.title")).font(.headline)
                Spacer()
                Text(LocalizedStringKey(manager.isModelBackedAdvisor ? "manager.badge.on_device" : "manager.badge.rule_based"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text(repo.name).font(.subheadline).foregroundColor(.secondary)
            Divider()

            if let advice {
                adviceBody(advice)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(LocalizedStringKey("manager.thinking")).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            }

            Spacer(minLength: 0)
            Text(LocalizedStringKey("manager.disclaimer")).font(.caption2).foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 480, height: 440)
        .task { advice = await manager.advice(for: repo) }
    }

    @ViewBuilder
    private func adviceBody(_ a: OffloadAdvice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: severityIcon(a.severity)).foregroundColor(severityColor(a.severity))
                Text(a.headline).font(.headline)
            }
            Text(a.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)

            if !a.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(a.steps.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s)").font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let q = a.clarifyingQuestion, !q.isEmpty {
                Text(q).font(.callout).italic().padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.1)).cornerRadius(6)
            }

            Divider().padding(.vertical, 2)

            HStack {
                ForEach(a.options) { opt in
                    if opt.action == .proceed || opt.action == .createPrivateRepo {
                        Button(opt.label) { onResolve(opt.action); dismiss() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(opt.label) { onResolve(opt.action); dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func severityIcon(_ s: AdviceSeverity) -> String {
        switch s {
        case .info: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        }
    }
    private func severityColor(_ s: AdviceSeverity) -> Color {
        switch s {
        case .info: return .green
        case .warning: return .orange
        case .blocking: return .red
        }
    }
}
