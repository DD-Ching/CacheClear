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
    @ObservedObject private var supporter = SupporterStore.shared

    @State private var mode: Mode = .offload
    @State private var presentation: Presentation = .list
    @State private var expanded: Set<String> = []
    @State private var adviceRepo: ProjectRepo?
    @State private var showSupporterSheet = false
    @State private var showConfirmOffload = false
    @State private var deleteNoPushRepo: ProjectRepo?
    @State private var trashCandidate: MapItem?

    enum Mode: String, CaseIterable, Identifiable {
        case offload, restore
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .offload: return "offload.mode.offload"
            case .restore: return "offload.mode.restore"
            }
        }
    }

    /// How the Offload tab presents its repos: a scrollable list or the treemap.
    enum Presentation: String, CaseIterable, Identifiable {
        case list, map
        var id: String { rawValue }
        var titleKey: String { self == .list ? "offload.present.list" : "offload.present.map" }
        var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
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

            if manager.lastError != nil { errorBanner }

            Group {
                if mode == .offload { offloadPane }
                else { restorePane }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay { if manager.isBusy { busyOverlay } }
        .sheet(item: $adviceRepo) { repo in
            AdviceSheet(repo: repo) { action in handle(action, for: repo) }
        }
        .sheet(isPresented: $showSupporterSheet) { SupporterSheet() }
        .sheet(isPresented: $showConfirmOffload) {
            OffloadConfirmSheet { dontAskAgain in
                if dontAskAgain { settings.skipOffloadConfirm = true }
                runOffload()
            }
        }
        .sheet(item: $deleteNoPushRepo) { repo in
            DeleteWithoutPushSheet(repo: repo) {
                Task { await manager.deleteWithoutPush(repo) }
            }
        }
        .confirmationDialog(
            Text(String(format: NSLocalizedString("map.trash.title", comment: ""),
                        PathDisplay.tilde(trashCandidate?.path ?? ""))),
            isPresented: Binding(get: { trashCandidate != nil },
                                 set: { if !$0 { trashCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("map.trash.confirm"), role: .destructive) {
                if let item = trashCandidate { Task { await manager.trashJunk(item) } }
                trashCandidate = nil
            }
            Button(LocalizedStringKey("offload.confirm.cancel"), role: .cancel) { trashCandidate = nil }
        } message: {
            Text(String(format: NSLocalizedString("map.trash.message", comment: ""),
                        ByteFormat.string(trashCandidate?.bytes ?? 0)))
        }
        .task(id: mode) {
            // Entering the Restore tab always shows a fresh list.
            if mode == .restore { await manager.refreshOffloads() }
        }
        .onChange(of: manager.restoreTabRequests) {
            // The menu bar's "Restore" item routes here.
            mode = .restore
        }
        .task {
            // First open with nothing chosen → scan common locations automatically.
            if manager.rootURL == nil && manager.repos.isEmpty && !manager.isBusy {
                await manager.scanDefaults()
            }
        }
        .task { await SponsorProvider.shared.refresh() }
    }

    // MARK: - Offload pane

    /// Failures were previously stored in `lastError` but never rendered —
    /// a failed restore or junk-trash looked like a silent success.
    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            Text(manager.lastError ?? "")
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { manager.lastError = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(LocalizedStringKey("offload.a11y.dismiss"))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.red.opacity(0.10))
    }

    private var offloadPane: some View {
        VStack(spacing: 0) {
            offloadHeader
            presentationToggle
            if presentation == .list && !manager.repos.isEmpty {
                if !supporter.isSupporter && !supporter.preUploadHeadsUpSeen {
                    preUploadHeadsUp
                }
                planBanner
            }
            Divider()
            if manager.repos.isEmpty {
                emptyState(manager.rootURL == nil ? "offload.empty.no_root" : "offload.empty.no_repos")
            } else if presentation == .map {
                mapContent
            } else {
                listContent
            }
            Divider()
            offloadFooter
        }
    }

    private var presentationToggle: some View {
        HStack {
            Picker("", selection: $presentation) {
                ForEach(Presentation.allCases) { p in
                    Label(LocalizedStringKey(p.titleKey), systemImage: p.icon).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if manager.eligibleRepos.count > 1 {
                    SizeThresholdSlider(
                        repos: manager.eligibleRepos,
                        onThreshold: { manager.selectBySizeThreshold(minBytes: $0) },
                        onToggle: { manager.toggle($0) }
                    )
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.repos) { repoRow($0) }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
    }

    private var mapContent: some View {
        TreemapView(items: manager.mapItems,
                    selected: Set(manager.repos.filter { $0.isSelected }.map { $0.id }),
                    sessionReclaimed: manager.sessionReclaimed,
                    onTap: onMapTap)
            .onAppear { manager.startMapBuild() }
            .onDisappear { manager.stopMapBuild() }
    }

    private struct RepoSection: Identifiable {
        let id: String
        let titleKey: String
        let icon: String
        let color: Color
        let repos: [ProjectRepo]
    }

    private var sections: [RepoSection] {
        let ready = manager.repos.filter {
            manager.results[$0.id] == nil &&
            ($0.report.status == .safeToOffload || $0.report.status == .needsPushFirst)
        }
        let attention = manager.repos.filter {
            manager.results[$0.id] == nil &&
            [SafetyStatus.noRemote, .conflictRisk, .hasLocalOnlySecrets, .blocked, .unknown].contains($0.report.status)
        }
        let done = manager.repos.filter { manager.results[$0.id] != nil }
        var out: [RepoSection] = []
        if !ready.isEmpty {
            out.append(RepoSection(id: "ready", titleKey: "offload.section.ready",
                                   icon: "checkmark.seal.fill", color: .green, repos: ready))
        }
        if !attention.isEmpty {
            out.append(RepoSection(id: "attention", titleKey: "offload.section.attention",
                                   icon: "exclamationmark.triangle.fill", color: .orange, repos: attention))
        }
        if !done.isEmpty {
            out.append(RepoSection(id: "done", titleKey: "offload.section.done",
                                   icon: "externaldrive.badge.checkmark", color: .secondary, repos: done))
        }
        return out
    }

    private func sectionHeader(_ s: RepoSection) -> some View {
        HStack(spacing: 7) {
            Image(systemName: s.icon).foregroundColor(s.color).font(.caption)
            Text(LocalizedStringKey(s.titleKey)).font(.subheadline).fontWeight(.semibold)
            Text("\(s.repos.count)").font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private var scopeShortLabel: String {
        if let url = manager.rootURL { return url.lastPathComponent }
        return NSLocalizedString("offload.scope.menu_defaults", comment: "")
    }

    private var offloadHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey("offload.root_label")).font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    // One scope control — the folder choices collapse into its menu.
                    Menu {
                        Button(LocalizedStringKey("offload.scan_defaults")) { Task { await manager.scanDefaults() } }
                        Button(LocalizedStringKey("offload.choose_root")) { chooseRoot() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            Text(scopeShortLabel).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(manager.isBusy)

                    Button(LocalizedStringKey("offload.rescan")) { Task { await manager.scan() } }
                        .disabled(manager.isBusy)

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
                Text(ByteFormat.string(manager.reclaimableBytes))
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

    /// One-line, once-ever, dismissible heads-up so the in-upload support card is
    /// never a surprise. Free users only; never blocks.
    private var preUploadHeadsUp: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart").foregroundColor(.secondary).font(.caption)
            Text(LocalizedStringKey("support.reminder.line"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { supporter.dismissPreUploadHeadsUp() } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }

    private var offloadFooter: some View {
        HStack {
            Text(String(format: NSLocalizedString("offload.summary_format", comment: ""),
                        manager.selectedRepos.count,
                        ByteFormat.string(manager.reclaimableBytes)))
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
                    Text(ageText(repo)).font(.caption)
                        .foregroundColor(repo.isRecentlyActive ? .orange : .secondary)
                }
                Spacer()
                if let result {
                    resultBadge(result)
                } else {
                    preflightBadge(repo.preflight)
                    statusBadge(repo.report.status)
                }
                Text(ByteFormat.string(repo.sizeBytes))
                    .font(.callout).foregroundColor(.secondary)
                    .frame(width: 72, alignment: .trailing)
                // Still a real Button: the whole-row tap is a convenience on top,
                // not a replacement — VoiceOver and keyboard need a focusable
                // control to reach the details.
                Button { toggleExpand(repo.id) } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LocalizedStringKey("offload.a11y.details"))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            // The WHOLE row expands, not just the tiny chevron; the checkbox stays
            // its own button and wins the hit test.
            .onTapGesture { toggleExpand(repo.id) }
            .background(RowHoverHighlight())
            .contextMenu {
                Button(LocalizedStringKey("offload.reveal_finder")) { reveal(repo) }
            }

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
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(format: NSLocalizedString("offload.a11y.select_format", comment: ""), repo.name)))
                .accessibilityValue(Text(repo.isSelected ? "1" : "0"))
            } else {
                Image(systemName: "square.slash").foregroundColor(.secondary.opacity(0.5))
            }
        }
        .frame(width: 22)
    }

    @ViewBuilder
    private func repoDetail(_ repo: ProjectRepo) -> some View {
        let r = repo.report
        let lose = r.secretOrDataIgnored.map(\.path) + r.atRiskOtherFiles
        VStack(alignment: .leading, spacing: 9) {
            // Concise summaries; the full file lists live in the hover tooltip.
            detailRow(icon: "arrow.up.circle.fill", color: .blue,
                      titleKey: "offload.group.will_push",
                      summary: pushSummary(r), full: r.untrackedFiles)
            if !r.regenerableIgnored.isEmpty {
                let paths = r.regenerableIgnored.map(\.path)
                detailRow(icon: "arrow.triangle.2.circlepath", color: .secondary,
                          titleKey: "offload.group.will_reclaim",
                          summary: shortNames(paths), full: paths)
            }
            if !r.strayWorktrees.isEmpty {
                detailRow(icon: "sparkles", color: .teal,
                          titleKey: "offload.group.will_tidy",
                          summary: shortNames(r.strayWorktrees), full: r.strayWorktrees)
            }
            if !lose.isEmpty {
                detailRow(icon: "exclamationmark.triangle.fill", color: .orange,
                          titleKey: "offload.group.will_lose",
                          summary: shortNames(lose), full: lose)
            }
            HStack(spacing: 16) {
                Button { reveal(repo) } label: {
                    Label(LocalizedStringKey("offload.reveal_finder"), systemImage: "folder")
                }.buttonStyle(.borderless)
                if repo.report.hasRemote && manager.results[repo.id] == nil {
                    Button(role: .destructive) { confirmDeleteWithoutPush(repo) } label: {
                        Label(LocalizedStringKey("offload.delete_no_push"), systemImage: "trash")
                    }.buttonStyle(.borderless)
                }
                if !repo.report.status.isAutoSelectable {
                    Button { adviceRepo = repo } label: {
                        Label(LocalizedStringKey("offload.ask_assistant"), systemImage: "wand.and.stars")
                    }.buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    /// One compact line per category: icon + title + a one-line summary. The full
    /// item list appears only on hover (native tooltip), keeping the row clean.
    private func detailRow(icon: String, color: Color, titleKey: String,
                           summary: String, full: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.caption).frame(width: 15)
            Text(LocalizedStringKey(titleKey)).font(.caption).fontWeight(.semibold).foregroundColor(color)
            Text(summary).font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if full.count > 1 {
                Image(systemName: "info.circle").font(.caption2).foregroundColor(.secondary.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
        .help(full.isEmpty ? "" : full.joined(separator: "\n"))
    }

    private func pushSummary(_ r: RepoSafetyReport) -> String {
        var parts: [String] = []
        if r.unpushedRefCount > 0 {
            parts.append(String(format: NSLocalizedString("offload.detail.commits_format", comment: ""), r.unpushedRefCount))
        }
        if r.dirtyTrackedCount > 0 {
            parts.append(String(format: NSLocalizedString("offload.detail.modified_format", comment: ""), r.dirtyTrackedCount))
        }
        if !r.untrackedFiles.isEmpty {
            parts.append(String(format: NSLocalizedString("offload.detail.newfiles_format", comment: ""), r.untrackedFiles.count))
        }
        return parts.isEmpty ? NSLocalizedString("offload.detail.all_pushed", comment: "") : parts.joined(separator: " · ")
    }

    /// First few base names, with a "+N" tail — the gist, not the dump.
    private func shortNames(_ items: [String], max: Int = 3) -> String {
        let names = items.map { p -> String in
            let t = (p as NSString).lastPathComponent
            return t.isEmpty ? p : t
        }
        let shown = names.prefix(max).joined(separator: ", ")
        return items.count > max ? "\(shown) +\(items.count - max)" : shown
    }

    private func reveal(_ repo: ProjectRepo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
    }

    /// Delete the local copy WITHOUT pushing (handed-off projects). Still verifies
    /// the remote has everything first; goes to Trash; never pushes. Presented as
    /// a SwiftUI sheet with an acknowledgement gate — the same strength as the
    /// push-and-reclaim confirm, since both end in a deleted working copy.
    private func confirmDeleteWithoutPush(_ repo: ProjectRepo) {
        deleteNoPushRepo = repo
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
                Text(ByteFormat.string(m.reclaimedBytes)).font(.caption).foregroundColor(.secondary)
                Button(LocalizedStringKey("restore.button")) { Task { await manager.restore(m) } }
                    .disabled(manager.isBusy)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
        }
    }

    // MARK: - Map interactions

    private func onMapTap(_ item: MapItem) {
        switch item.kind {
        case .repo:
            if item.repoSelectable { manager.toggle(item.id) }
        case .junkAuto:
            confirmTrash(item)
        case .junkShowOnly, .other:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
    }

    private func confirmTrash(_ item: MapItem) {
        // Shows the real path (e.g. ~/.gradle/caches) in a non-blocking SwiftUI
        // confirmation dialog — see body. Never a bare ambiguous name.
        trashCandidate = item
    }

    // MARK: - Shared

    /// Empty states carry the action that fixes them instead of dead-ending.
    private func emptyState(_ key: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundColor(.secondary)
            Text(LocalizedStringKey(key)).foregroundColor(.secondary)
            if mode == .offload {
                HStack(spacing: 8) {
                    Button(LocalizedStringKey("offload.empty.cta_defaults")) {
                        Task { await manager.scanDefaults() }
                    }
                    Button(LocalizedStringKey("offload.empty.cta_choose")) { chooseRoot() }
                }
                .disabled(manager.isBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            Group {
                if isCardMoment && !supporter.isSupporter {
                    VStack(spacing: 12) {
                        SupporterCard { showSupporterSheet = true }
                        cancelButton
                    }
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(phaseText).font(.callout)
                        if let p = manager.queueProgress, p.total > 1 {
                            Text(String(format: NSLocalizedString("offload.queue_progress_format", comment: ""),
                                        p.done + 1, p.total))
                                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                        }
                        if !manager.statusLine.isEmpty {
                            Text(manager.statusLine).font(.caption).foregroundColor(.secondary)
                        }
                        if supporter.isSupporter && isCardMoment {
                            Text(LocalizedStringKey("support.card.thanks_member"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        cancelButton
                    }
                    .padding(24)
                }
            }
            .background(.regularMaterial)
            .cornerRadius(12)
            .animation(.easeInOut(duration: 0.25), value: isCardMoment)
        }
    }

    /// Scans cancel instantly; a queued offload stops after the current project
    /// (a repo is either fully offloaded and verified, or untouched). Restores
    /// are short and atomic, so they offer no cancel.
    @ViewBuilder
    private var cancelButton: some View {
        switch manager.phase {
        case .scanning:
            Button(LocalizedStringKey("offload.cancel_button")) { manager.cancelScan() }
                .keyboardShortcut(.cancelAction)
        case .offloading:
            if let p = manager.queueProgress, p.total > 1 {
                Button(LocalizedStringKey("offload.cancel_button")) { manager.cancelQueuedOffloads() }
                    .keyboardShortcut(.cancelAction)
            }
        default:
            EmptyView()
        }
    }

    /// Moments worth showing the supporter card: the live scan and the live push.
    private var isCardMoment: Bool {
        switch manager.phase {
        case .scanning: return true
        case .offloading(_, .push): return true
        default: return false
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
        Text(LocalizedStringKey(status.labelKey))
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(status.tint.opacity(0.18)).foregroundColor(status.tint).cornerRadius(5)
    }

    @ViewBuilder
    private func preflightBadge(_ p: PreflightStatus) -> some View {
        switch p {
        case .confirmed:
            Image(systemName: "checkmark.seal.fill").font(.caption).foregroundColor(.green)
                .help(LocalizedStringKey("offload.preflight.confirmed"))
        case .willCreateRepo:
            Image(systemName: "plus.circle").font(.caption).foregroundColor(.orange)
                .help(LocalizedStringKey("offload.preflight.will_create"))
        case .checking:
            ProgressView().controlSize(.small)
                .help(LocalizedStringKey("offload.preflight.checking"))
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
        guard let s = repo.secondsIdle else { return NSLocalizedString("offload.age.unknown", comment: "") }
        if s < 3600 { return NSLocalizedString("offload.age.just_now", comment: "") }
        if s < 86400 {
            return String(format: NSLocalizedString("offload.age.hours_format", comment: ""), Int(s / 3600))
        }
        return String(format: NSLocalizedString("offload.age.days_format", comment: ""), Int(s / 86400))
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
        // "Don't ask me again" → go straight to offload. The verify-before-delete
        // safety gate still runs; only the confirmation dialog is skipped.
        if settings.skipOffloadConfirm {
            runOffload()
            return
        }
        // Present a SwiftUI sheet rather than an NSAlert. NSAlert's accessory-view
        // controls (the acknowledgement and "don't ask again" checkboxes) don't
        // reliably draw until the alert window receives a mouse event — a known
        // AppKit bug — so the boxes were invisible until clicked blindly, which
        // could leave the destructive button permanently disabled. A sheet draws
        // its controls immediately.
        showConfirmOffload = true
    }

    private func runOffload() {
        Task {
            await manager.offloadSelected()
            supporter.dismissPreUploadHeadsUp()   // fallback: never nag after a real upload
        }
    }
}

/// The badge colour for a safety status — lives beside the views so the model
/// layer stays UI-free, but every surface (list + map) shares one mapping.
extension SafetyStatus {
    var tint: Color {
        switch self {
        case .safeToOffload: return .green
        case .needsPushFirst: return .blue
        case .noRemote: return .orange
        case .hasLocalOnlySecrets: return .red
        case .conflictRisk: return .purple
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
}

/// Subtle hover wash for list rows, so the row reads as clickable.
private struct RowHoverHighlight: View {
    @State private var hovering = false
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(hovering ? 0.05 : 0))
            .onHover { hovering = $0 }
    }
}

// MARK: - Delete-without-pushing confirmation sheet

/// The delete-without-push confirm, upgraded from a plain NSAlert to the same
/// acknowledgement-gated sheet as push & reclaim — both flows end in a deleted
/// working copy, so both get the same two-gate strength.
struct DeleteWithoutPushSheet: View {
    let repo: ProjectRepo
    /// Called only when the user confirms.
    var onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.yellow)
                Text(String(format: NSLocalizedString("offload.delete_no_push.title", comment: ""), repo.name))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(LocalizedStringKey("offload.delete_no_push.message"))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $acknowledged) {
                Text(LocalizedStringKey("offload.delete_no_push.ack"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button(LocalizedStringKey("offload.confirm.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    onConfirm()
                    dismiss()
                } label: {
                    Text(LocalizedStringKey("offload.delete_no_push.confirm"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!acknowledged)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Push & Reclaim confirmation sheet

/// Confirmation before a destructive push & reclaim. A SwiftUI sheet replaces
/// the old NSAlert: NSAlert's accessory-view controls don't reliably draw until
/// the alert window gets a mouse event (a long-standing AppKit bug), so the
/// checkboxes were invisible until clicked blindly. A sheet renders immediately
/// and keeps the same two-gate behavior: the destructive button stays disabled
/// until the acknowledgement toggle is on.
struct OffloadConfirmSheet: View {
    /// Called only when the user confirms; passes whether to skip future prompts.
    var onConfirm: (_ dontAskAgain: Bool) -> Void

    @ObservedObject private var manager = OffloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.yellow)
                Text(LocalizedStringKey("offload.confirm.title"))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(String(format: NSLocalizedString("offload.confirm.message", comment: ""),
                        manager.selectedRepos.count,
                        ByteFormat.string(manager.reclaimableBytes)))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $acknowledged) {
                    Text(LocalizedStringKey("offload.confirm.checkbox"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $dontAskAgain) {
                    Text(LocalizedStringKey("offload.confirm.dont_ask"))
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button(LocalizedStringKey("offload.confirm.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    onConfirm(dontAskAgain)
                    dismiss()
                } label: {
                    Text(LocalizedStringKey("offload.confirm.confirm"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!acknowledged)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
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
