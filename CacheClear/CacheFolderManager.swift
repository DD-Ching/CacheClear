//
//  CacheFolderManager.swift
//  CacheClear
//
//  Created by Codex on 2026/1/25.
//

import AppKit
import Combine

final class CacheFolderManager: ObservableObject {
    static let shared = CacheFolderManager()

    @Published private(set) var selectedURL: URL?

    private let bookmarkKey = "cacheFolderBookmark"
    private let pathKey = "cacheFolderPath"

    /// Security-scoped bookmarks are a sandbox feature; when the app runs
    /// unsandboxed we store/resolve plain bookmarks (and a path fallback).
    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
    private var bookmarkCreateOptions: URL.BookmarkCreationOptions {
        isSandboxed ? [.withSecurityScope] : []
    }
    private var bookmarkResolveOptions: URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope, .withoutUI] : [.withoutUI]
    }

    private init() {
        loadBookmark()
    }

    var displayPath: String {
        selectedURL?.path ?? NSLocalizedString("settings.cache_folder.unset", comment: "")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = NSLocalizedString("settings.cache_folder.panel_title", comment: "")
        panel.message = NSLocalizedString("settings.cache_folder.panel_message", comment: "")
        panel.prompt = NSLocalizedString("settings.cache_folder.choose_button", comment: "")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // Only a real cache location may be chosen — refuse Mail/Keychains/
            // system/other-user/volume folders up front, with clear feedback.
            guard PathSafety.isClearableCacheLocation(url) else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("settings.cache_folder.rejected_title", comment: "")
                alert.informativeText = String(format: NSLocalizedString("settings.cache_folder.rejected_message", comment: ""), url.path)
                alert.addButton(withTitle: NSLocalizedString("alert.ok", comment: ""))
                alert.runModal()
                return
            }
            self?.setSelectedURL(url)
        }
    }

    func clearSelection() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
        selectedURL = nil
    }

    private func setSelectedURL(_ url: URL) {
        selectedURL = url
        UserDefaults.standard.set(url.path, forKey: pathKey)
        do {
            let data = try url.bookmarkData(
                options: bookmarkCreateOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            // Bookmark save failed; the plain path fallback still persists the choice.
        }
    }

    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            loadPathFallback()
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: bookmarkResolveOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Reject a stale bookmark that now points somewhere unsafe.
            guard PathSafety.isClearableCacheLocation(url) else { return }
            if isStale {
                setSelectedURL(url)
            } else {
                selectedURL = url
            }
        } catch {
            // A bookmark minted under the sandbox can fail to resolve once the
            // sandbox is removed — fall back to the stored path.
            loadPathFallback()
        }
    }

    private func loadPathFallback() {
        guard let path = UserDefaults.standard.string(forKey: pathKey) else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) && PathSafety.isClearableCacheLocation(url) {
            selectedURL = url
        }
    }
}
