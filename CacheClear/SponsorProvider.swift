//
//  SponsorProvider.swift
//  CacheClear
//
//  Holds the current sponsor slot contents. Defaults to the built-in "support the
//  author" card. If the author sets `feedURL` to a JSON file they host, the app
//  fetches it (cached to disk, with graceful fallback) so ads can be changed
//  WITHOUT shipping an app update. The fetch is a plain GET of a static file and
//  sends NO user or repo data — nothing about the user's projects leaves the Mac.
//

import Foundation
import Combine

@MainActor
final class SponsorProvider: ObservableObject {
    static let shared = SponsorProvider()

    /// The slot rotates through these. Always non-empty.
    @Published private(set) var ads: [SponsorAd] = [.supportAuthor]

    /// A JSON feed the AUTHOR hosts to swap ads without re-releasing.
    /// nil → built-in support-author card only.
    /// Format: [{ "id": "...", "headline": "...", "subhead"?: "...",
    ///            "imageURL"?: "https://…", "linkURL"?: "https://…" }]
    /// TODO: set to your hosted ads.json (e.g. a GitHub raw URL or a CDN).
    private let feedURL: URL? = nil

    private init() {
        if let cached = loadCache(), !cached.isEmpty { ads = cached }
    }

    /// Refresh from the cloud feed if one is configured. Safe to call on every
    /// window open; no-ops cleanly when offline or unset, keeping current ads.
    func refresh() async {
        guard let feedURL else { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: feedURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode([SponsorAd].self, from: data),
              !decoded.isEmpty else { return }
        saveCache(data)
        ads = decoded
    }

    // MARK: - Disk cache

    private func cacheURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CacheClear", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sponsors.json")
    }

    private func loadCache() -> [SponsorAd]? {
        guard let data = try? Data(contentsOf: cacheURL()) else { return nil }
        return try? JSONDecoder().decode([SponsorAd].self, from: data)
    }

    private func saveCache(_ data: Data) {
        try? data.write(to: cacheURL())
    }
}
