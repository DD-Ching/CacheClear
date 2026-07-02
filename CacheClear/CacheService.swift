//
//  CacheService.swift
//  CacheClear
//
//  The disk work behind the menu bar: sizing the cache folder, Clear Cache and
//  Deep Clean. Extracted from AppDelegate so the delegate only orchestrates UI.
//  Guarantees preserved: Clear Cache is positively scoped
//  (PathSafety.isClearableCacheLocation) and Trash-only; Deep Clean touches only
//  the vetted developer-cache list, each item gated by PathSafety — and it now
//  moves them to the Trash too, so nothing it deletes is unrecoverable.
//

import Foundation

@MainActor
final class CacheService {
    static let shared = CacheService()
    private init() {}

    private let folderManager = CacheFolderManager.shared

    // MARK: - Cache folder (Clear Cache)

    /// Allocated size of the selected cache folder in bytes, or nil when no
    /// folder is chosen or it can't be accessed.
    func cacheSizeBytes() async -> UInt64? {
        guard let url = folderManager.selectedURL else { return nil }
        let isAccessing = url.startAccessingSecurityScopedResource()
        guard isAccessing else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        #if MAS_BUILD
        // Sandboxed: a spawned `du` does not inherit this process's
        // security-scoped access, so size in-process. Slower, but correct.
        return await Task.detached(priority: .userInitiated) {
            Self.enumeratedSize(at: url)
        }.value
        #else
        return await DiskUsage.bytes(atPath: url.path)
        #endif
    }

    #if MAS_BUILD
    /// In-process recursive allocated-size walk for the sandboxed edition —
    /// hidden files included, matching `du`'s semantics as closely as possible.
    nonisolated private static func enumeratedSize(at root: URL) -> UInt64 {
        var total: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                    total += UInt64(size)
                }
            }
        }
        return total
    }
    #endif

    /// Trash the contents of the selected cache folder. Returns the bytes
    /// trashed, or nil when no folder is set or it can't be accessed.
    func clearCache() async -> UInt64? {
        guard let url = folderManager.selectedURL else { return nil }
        let isAccessing = url.startAccessingSecurityScopedResource()
        guard isAccessing else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return await Task.detached(priority: .userInitiated) {
            Self.clearContents(at: url)
        }.value
    }

    /// Positively scoped: only a real cache location may be cleared, so a
    /// mis-selected folder can never be wiped. And it goes to the Trash
    /// (recoverable), not a permanent delete.
    nonisolated private static func clearContents(at cachesURL: URL) -> UInt64 {
        let fileManager = FileManager.default
        var clearedSize: UInt64 = 0

        guard PathSafety.isClearableCacheLocation(cachesURL) else {
            NSLog("CacheClear: refused to clear non-cache location \(cachesURL.path)")
            return 0
        }

        if let contents = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for item in contents where PathSafety.isSafeToDelete(item) {
                if let size = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                    clearedSize += UInt64(size)
                }
                var resulting: NSURL?
                try? fileManager.trashItem(at: item, resultingItemURL: &resulting)
            }
        }

        return clearedSize
    }

    // MARK: - Deep Clean

    nonisolated struct DeepCleanOutcome: Sendable {
        var failures = 0
    }

    /// Trash the vetted developer caches (DerivedData, old simulators, device
    /// support, SwiftPM/CocoaPods caches) and run the standard tool cleanups.
    /// Reports how many steps failed so the UI can stop pretending everything
    /// always succeeds.
    func deepClean() async -> DeepCleanOutcome {
        await Task.detached(priority: .userInitiated) {
            Self.runDeepClean()
        }.value
    }

    nonisolated private static func runDeepClean() -> DeepCleanOutcome {
        var outcome = DeepCleanOutcome()
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        func trashIfExists(_ url: URL) {
            guard fileManager.fileExists(atPath: url.path) else { return }
            guard PathSafety.isSafeToDelete(url) else {
                NSLog("CacheClear: refused to delete protected path \(url.path)")
                outcome.failures += 1
                return
            }
            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
                NSLog("Deep clean failed to trash \(url.path): \(error)")
                outcome.failures += 1
            }
        }

        if !runProcess("/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"]) {
            outcome.failures += 1
        }
        trashIfExists(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        trashIfExists(home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"))
        trashIfExists(home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"))
        // Xcode/Archives is deliberately NOT touched: release archives + dSYMs
        // are irreplaceable build products, not caches.
        trashIfExists(home.appendingPathComponent("Library/Caches/org.swift.swiftpm"))
        trashIfExists(home.appendingPathComponent("Library/Caches/CocoaPods"))

        // Tool caches: only counted as failures when the tool is installed.
        // (`brew autoremove` is deliberately NOT run — it uninstalls packages,
        // which is beyond cache cleaning.)
        runShellIfToolPresent("brew", command: "yes | brew cleanup -s", outcome: &outcome)
        runShellIfToolPresent("npm", command: "npm cache clean --force", outcome: &outcome)

        return outcome
    }

    nonisolated private static func runShellIfToolPresent(_ tool: String, command: String, outcome: inout DeepCleanOutcome) {
        guard runShellCommand("command -v \(tool) >/dev/null") else { return }
        if !runShellCommand(command) { outcome.failures += 1 }
    }

    @discardableResult
    nonisolated private static func runProcess(_ launchPath: String, arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("Deep clean failed to run \(launchPath): \(error)")
            return false
        }
    }

    @discardableResult
    nonisolated private static func runShellCommand(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("Deep clean failed to run shell command: \(command) error: \(error)")
            return false
        }
    }
}
