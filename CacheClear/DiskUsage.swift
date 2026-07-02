//
//  DiskUsage.swift
//  CacheClear
//
//  On-disk directory sizing via `du -sk` — an fts(3)-based walk in C, far
//  faster than a per-file FileManager enumeration, and it counts what actually
//  frees up: allocated blocks, hidden files included. Lives on its own so the
//  menu-bar cache size and the offload scanner report the same numbers, and
//  GitCommandRunner stays purely about git/gh.
//

import Foundation

nonisolated enum DiskUsage {
    /// Size of the directory at `path` in bytes; 0 on failure or cancellation.
    nonisolated static func bytes(atPath path: String, timeout: TimeInterval = 180) async -> UInt64 {
        if Task.isCancelled { return 0 }   // an abandoned map build spawns nothing
        let process = Process()
        // Cancellation terminates the child — a long `du` over node_modules
        // shouldn't outlive the view that asked for it.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UInt64, Never>) in
                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sk", path]
                process.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe

                let resumed = ResumeOnce()
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                // du prints a single line, so reading only after exit cannot deadlock
                // against a full pipe buffer.
                process.terminationHandler = { _ in
                    watchdog.cancel()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: data, as: UTF8.self)
                    let field = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? "0"
                    resumed.fire { continuation.resume(returning: (UInt64(field) ?? 0) * 1024) }
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                } catch {
                    watchdog.cancel()
                    resumed.fire { continuation.resume(returning: 0) }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
