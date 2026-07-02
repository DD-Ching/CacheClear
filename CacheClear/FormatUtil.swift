//
//  FormatUtil.swift
//  CacheClear
//
//  Tiny shared formatting helpers. One implementation each — the menu bar, the
//  offload list, the map and the manifests must all print the same string for
//  the same byte count, and every surface abbreviates home paths the same way.
//

import Foundation

nonisolated enum ByteFormat {
    /// Fixed 1024-based units with one decimal for MB/GB — deliberately not
    /// ByteCountFormatter so every surface agrees on the exact same string.
    static func string(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024, mb = kb / 1024, gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", kb)
    }
}

nonisolated enum PathDisplay {
    /// Abbreviate a home-relative path with ~ for compact, unambiguous display.
    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
