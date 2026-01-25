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
            self?.setSelectedURL(url)
        }
    }

    func clearSelection() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        selectedURL = nil
    }

    func withSecurityScopedAccess<T>(_ handler: (URL) throws -> T) rethrows -> T? {
        guard let url = selectedURL else { return nil }
        let isAccessing = url.startAccessingSecurityScopedResource()
        guard isAccessing else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try handler(url)
    }

    private func setSelectedURL(_ url: URL) {
        selectedURL = url
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            // Bookmark save failed; keep selection for this session.
        }
    }

    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }

        if isStale {
            setSelectedURL(url)
        } else {
            selectedURL = url
        }
    }
}
