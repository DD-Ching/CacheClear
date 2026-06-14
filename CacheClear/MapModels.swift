//
//  MapModels.swift
//  CacheClear
//
//  Models + classification + layout for the "Map" tab: a disk treemap that
//  colours each block by what it is — a git repo you can offload (green),
//  regenerable junk you can one-click Trash (red), regenerable-but-ambiguous
//  stuff you can only reveal (orange), or anything else (gray).
//
//  The one-click DELETE path is gated by JunkClassifier, which uses EXACT folder
//  names + toolchain manifests + git proof — never loose substring matching — so
//  the tool can never offer to delete something the user might actually need.
//

import SwiftUI
import AppKit

enum MapKind: Sendable, Hashable {
    case repo           // green   — tapping toggles offload selection
    case junkAuto       // red     — autoDeletable: tap → confirm → Trash
    case junkShowOnly   // orange  — regenerable but ambiguous: reveal only
    case other          // gray    — not actionable

    var fill: Color {
        switch self {
        case .repo:         return Color.green.opacity(0.80)
        case .junkAuto:     return Color.red.opacity(0.80)
        case .junkShowOnly: return Color.orange.opacity(0.45)
        case .other:        return Color(nsColor: .systemGray).opacity(0.45)
        }
    }
    var textColor: Color { (self == .other || self == .junkShowOnly) ? .primary : .white }
    var isDeletable: Bool { self == .junkAuto }
    var isSelectable: Bool { self == .repo }
}

struct MapItem: Identifiable, Sendable, Hashable {
    let id: String          // absolute path — stable identity
    let name: String
    let path: String
    var bytes: UInt64       // var: a repo's green block shrinks as its junk is split out
    let kind: MapKind
    var repoSelectable: Bool = true
    var subtitle: String?   // hover detail: repo slug, or junk's ~-path
    var badge: String?      // hover detail: status / "clearable" / "regenerable"
}

struct LaidOutBlock: Identifiable, Hashable {
    let item: MapItem
    let rect: CGRect
    var id: String { item.id }
}

// MARK: - Junk classification (the vetted safelist)

enum JunkVerdict { case autoDeletable, showOnly, notJunk }

enum JunkClassifier {
    /// Exact folder names, case-sensitive — always regenerable, safe to one-click Trash.
    static let autoNames: Set<String> = [
        "node_modules", ".build", ".next", ".turbo", "__pycache__",
        ".parcel-cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".angular", ".svelte-kit", ".nuxt", ".astro", ".docusaurus",
    ]
    /// Regenerable but ambiguous → shown, never one-click.
    static let showOnlyPlain: Set<String> = [".cache", ".terraform", "out"]
    /// name → at least one of these sibling manifests must exist (else not junk).
    static let gated: [String: [String]] = [
        "Pods":   ["Podfile"],
        "target": ["Cargo.toml", "pom.xml"],
        "build":  ["CMakeLists.txt", "build.gradle", "build.gradle.kts"],
        "dist":   ["package.json"],
        "vendor": ["composer.json"],   // Go vendor handled as a hard exclusion below
        "bin":    [],
        "obj":    [],
    ]
    static let hardExcludedNames: Set<String> = [".git", ".github"]

    static func verdict(for dir: URL, gitIgnored: Bool, gitTracked: Bool, inICloud: Bool) -> JunkVerdict {
        let name = dir.lastPathComponent
        let fm = FileManager.default
        let parent = dir.deletingLastPathComponent()
        func sibling(_ f: String) -> Bool { fm.fileExists(atPath: parent.appendingPathComponent(f).path) }
        func siblingHasSuffix(_ suffix: String) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).contains { $0.hasSuffix(suffix) }
        }

        if hardExcludedNames.contains(name) { return .notJunk }
        if gitTracked { return .notJunk }                 // committed work — name is irrelevant
        if inICloud {                                     // iCloud Trash is flaky → never one-click
            return (showOnlyPlain.contains(name) || autoNames.contains(name) || gated[name] != nil) ? .showOnly : .notJunk
        }

        if let manifests = gated[name] {
            if name == "vendor", sibling("go.mod") { return .notJunk }   // Go vendor = committed offline source
            if name == "bin" || name == "obj" {
                return (siblingHasSuffix(".csproj") || siblingHasSuffix(".sln")) ? .showOnly : .notJunk
            }
            return manifests.contains(where: sibling) ? .showOnly : .notJunk
        }
        if name == ".venv" || name == "venv" || name == "env" {
            let hasCfg = sibling("pyvenv.cfg") || fm.fileExists(atPath: dir.appendingPathComponent("pyvenv.cfg").path)
            return hasCfg ? .showOnly : .notJunk
        }
        if showOnlyPlain.contains(name) { return .showOnly }
        if autoNames.contains(name) { return .autoDeletable }
        return .notJunk
    }

    /// Well-known global caches matched by absolute path (never by bare token).
    static func globalAutoDeletable(home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
         home.appendingPathComponent(".gradle/caches")]
    }
}

// MARK: - Squarified treemap layout

enum Squarify {
    /// Lay `items` (any order; sorted internally, descending) into `rect`.
    /// Classic Bruls/Huizing/van Wijk squarified treemap.
    static func layout(_ items: [MapItem], in rect: CGRect) -> [LaidOutBlock] {
        let pos = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard !pos.isEmpty, rect.width > 2, rect.height > 2 else { return [] }

        let total = pos.reduce(0.0) { $0 + Double($1.bytes) }
        let scale = Double(rect.width) * Double(rect.height) / total
        let areas = pos.map { Double($0.bytes) * scale }

        var blocks: [LaidOutBlock] = []
        var remaining = rect
        var row: [Int] = []
        var i = 0
        let n = pos.count

        func shortSide(_ r: CGRect) -> Double { Double(min(r.width, r.height)) }

        func worst(_ rowIdx: [Int], _ side: Double) -> Double {
            guard !rowIdx.isEmpty, side > 0 else { return .greatestFiniteMagnitude }
            var sum = 0.0, mx = 0.0, mn = Double.greatestFiniteMagnitude
            for idx in rowIdx { let a = areas[idx]; sum += a; mx = max(mx, a); mn = min(mn, a) }
            guard sum > 0 else { return .greatestFiniteMagnitude }
            let s2 = side * side, sum2 = sum * sum
            return max(s2 * mx / sum2, sum2 / (s2 * mn))
        }

        func layoutRow(_ rowIdx: [Int]) {
            let rowArea = rowIdx.reduce(0.0) { $0 + areas[$1] }
            let side = shortSide(remaining)
            guard side > 0, rowArea > 0 else { return }
            let thickness = rowArea / side
            let horizontal = remaining.width >= remaining.height
            if horizontal {
                var y = remaining.minY
                for idx in rowIdx {
                    let h = areas[idx] / thickness
                    blocks.append(LaidOutBlock(item: pos[idx],
                                               rect: CGRect(x: remaining.minX, y: y, width: thickness, height: h)))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: remaining.width - thickness, height: remaining.height)
            } else {
                var x = remaining.minX
                for idx in rowIdx {
                    let w = areas[idx] / thickness
                    blocks.append(LaidOutBlock(item: pos[idx],
                                               rect: CGRect(x: x, y: remaining.minY, width: w, height: thickness)))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: remaining.height - thickness)
            }
        }

        while i < n {
            let side = shortSide(remaining)
            if row.isEmpty || worst(row + [i], side) <= worst(row, side) {
                row.append(i)
                i += 1
            } else {
                layoutRow(row)
                row = []
            }
        }
        if !row.isEmpty { layoutRow(row) }
        return blocks
    }
}
