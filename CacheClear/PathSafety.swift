//
//  PathSafety.swift
//  CacheClear
//
//  The single guard EVERY deletion must pass. Two layers:
//   • isProtected/isSafeToDelete — a conservative blocklist for all deletions:
//     refuses "/", any system/framework root AND its descendants, other users'
//     and shared data, whole mounted volumes, the home folder and its sensitive
//     top-level subfolders. Paths are symlink-resolved + standardized first
//     (so /var→/private/var, case-folding, and symlink tricks are handled).
//   • isClearableCacheLocation — a POSITIVE allowlist for the "Clear Cache"
//     feature: it may only wipe a folder under the user's home, and if that
//     folder is under ~/Library it must be within Caches or Developer — never
//     Mail, Messages, Keychains, Containers, Application Support, etc.
//

import Foundation

nonisolated enum PathSafety {
    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    private static var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True if `url` must never be deleted (nor have its contents cleared).
    static func isProtected(_ url: URL) -> Bool {
        let path = canonical(url)
        let home = homePath
        if path == "/" { return true }

        let underOwnHome = (path == home) || path.hasPrefix(home + "/")

        // System / framework / volume / users roots AND all their descendants
        // (the only exception under /Users is the current user's own home tree).
        let systemRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc",
                           "/var", "/tmp", "/private", "/opt", "/cores",
                           "/Applications", "/Network", "/dev", "/home",
                           "/Volumes", "/Users"]
        for root in systemRoots {
            if path == root { return true }
            if path.hasPrefix(root + "/") {
                if root == "/Users" && underOwnHome { break }  // own home handled below
                return true
            }
        }

        // A single component under root (e.g. "/Foo") — a mount or system dir.
        let comps = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        if comps.count <= 1 { return true }

        // The home folder itself and its sensitive top-level subfolders.
        if path == home { return true }
        let homeSub = ["Library", "Documents", "Desktop", "Downloads", "Movies",
                       "Music", "Pictures", "Public", "Applications",
                       ".ssh", ".config", ".gnupg", ".aws", ".kube", ".docker"]
        if homeSub.contains(where: { path == home + "/" + $0 }) { return true }

        return false
    }

    static func isSafeToDelete(_ url: URL) -> Bool { !isProtected(url) }

    /// Positive allowlist for the "Clear Cache" feature. Only a real cache
    /// location may be cleared, so a mis-selection can never wipe important data.
    static func isClearableCacheLocation(_ url: URL) -> Bool {
        let path = canonical(url)
        let home = homePath
        guard path.hasPrefix(home + "/") else { return false }   // strictly inside home
        guard isSafeToDelete(url) else { return false }
        let lib = home + "/Library"
        if path == lib || path.hasPrefix(lib + "/") {
            // Under ~/Library only Caches / Developer may be cleared.
            let allowed = [lib + "/Caches", lib + "/Developer"]
            return allowed.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        return true
    }
}
