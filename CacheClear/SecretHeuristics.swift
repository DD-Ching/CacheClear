//
//  SecretHeuristics.swift
//  CacheClear
//
//  The ONE list of filename patterns treated as likely secrets or irreplaceable
//  data. Both the scan-time classifier and the last-moment rescan that runs
//  before any PERMANENT reclaim read this list — if the two ever diverged, a
//  file could be classified safe at scan time yet missed by the rescan, so the
//  patterns live in exactly one place.
//

import Foundation

nonisolated enum SecretHeuristics {
    /// Basename fragments that mark a file as a likely secret.
    /// Matched with `contains` on the lowercased basename.
    static let secretFragments = [
        ".env", "credentials", "service-account", "id_rsa", "id_ed25519",
        ".pem", ".key", ".p12", ".keystore", ".pfx", "secret",
    ]

    /// Basename suffixes that mark a file as a likely local database or dump.
    static let dataSuffixes = [".sqlite", ".db", ".dump", ".sql"]

    static func isSecretName(_ basename: String) -> Bool {
        let lower = basename.lowercased()
        return secretFragments.contains { lower.contains($0) }
    }

    static func isDataName(_ basename: String) -> Bool {
        let lower = basename.lowercased()
        return dataSuffixes.contains { lower.hasSuffix($0) }
    }
}
