//
//  PathSafety.swift
//  CacheClear
//
//  A single, conservative guard that EVERY deletion in the app must pass. It is
//  the backstop behind the feature-level safety (verify-before-delete, Trash
//  defaults, the junk safelist): even a misconfiguration or a bug can never make
//  the app delete a system directory, the home folder, a standard top-level
//  folder (Documents/Desktop/Downloads/Library…), a whole volume, or anything
//  resolved (through symlinks) into those. Caches and project folders sit safely
//  below these and are unaffected.
//

import Foundation

enum PathSafety {
    /// True if `url` must never be deleted (nor have its contents cleared).
    static func isProtected(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path

        // System / volume / other-users roots.
        let systemRoots: Set<String> = [
            "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var",
            "/tmp", "/private", "/opt", "/cores", "/Applications", "/Users",
            "/Volumes", "/Network", "/dev", "/home",
        ]
        if systemRoots.contains(path) { return true }
        if path.hasPrefix("/System/") { return true }

        // A single component under root (e.g. "/Foo") — a mount or system dir.
        let comps = resolved.pathComponents.filter { $0 != "/" }
        if comps.count <= 1 { return true }

        // The root of any mounted volume (e.g. "/Volumes/Backup") — never wipe a drive.
        if path.hasPrefix("/Volumes/") && comps.count <= 2 { return true }

        // The home folder itself and its standard top-level subfolders.
        let homeProtected: Set<String> = [
            home,
            home + "/Library", home + "/Documents", home + "/Desktop",
            home + "/Downloads", home + "/Movies", home + "/Music",
            home + "/Pictures", home + "/Public", home + "/Applications",
            home + "/.ssh", home + "/.config", home + "/.gnupg",
        ]
        if homeProtected.contains(path) { return true }

        return false
    }

    static func isSafeToDelete(_ url: URL) -> Bool { !isProtected(url) }
}
