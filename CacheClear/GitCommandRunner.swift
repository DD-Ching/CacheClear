//
//  GitCommandRunner.swift
//  CacheClear
//
//  The single choke point for spawning `git` and `gh`. Builds an explicit
//  environment so credentials resolve even though the app launches from the GUI
//  (where PATH is minimal and `~/.gitconfig` has no credential helper wired).
//

import Foundation

nonisolated struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { exitCode == 0 }
    var out: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var message: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

nonisolated struct CommandError: Error, LocalizedError {
    let command: String
    let result: CommandResult
    var errorDescription: String? {
        "\(command) (exit \(result.exitCode)): \(result.message)"
    }
}

actor GitCommandRunner {
    static let shared = GitCommandRunner()

    enum Tool { case git, gh }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private lazy var gitPath: String =
        Self.firstExecutable(["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]) ?? "/usr/bin/git"

    private lazy var ghPath: String? =
        Self.firstExecutable(["\(home)/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"])

    var isGHAvailable: Bool { ghPath != nil }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin:/Library/Developer/CommandLineTools/usr/libexec/git-core"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"          // never block the GUI on an invisible prompt
        env["GIT_ASKPASS"] = "/usr/bin/false"
        // No -i here: forcing id_rsa broke every ed25519-only setup. ssh already
        // tries the user's configured/default identities; we only forbid prompts.
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        return env
    }

    /// Per-invocation credential wiring: clears any inherited helper then points
    /// git at the gh credential helper. This mirrors what `gh auth setup-git`
    /// writes, but transiently so we never mutate the user's `~/.gitconfig`.
    private func credentialArgs() -> [String] {
        guard let gh = ghPath else { return [] }
        return [
            "-c", "credential.https://github.com.helper=",
            "-c", "credential.https://github.com.helper=!\(gh) auth git-credential",
        ]
    }

    @discardableResult
    func git(_ args: [String], in cwd: URL, network: Bool = false, timeout: TimeInterval = 600) async throws -> CommandResult {
        let full = (network ? credentialArgs() : []) + args
        return try await run(launchPath: gitPath, args: full, cwd: cwd, timeout: timeout)
    }

    /// Runs git and throws CommandError on a non-zero exit (use for steps that
    /// must succeed; use `git(...)` directly when you want to inspect exit codes).
    @discardableResult
    func gitChecked(_ args: [String], in cwd: URL, network: Bool = false, timeout: TimeInterval = 600) async throws -> CommandResult {
        let result = try await git(args, in: cwd, network: network, timeout: timeout)
        guard result.ok else {
            throw CommandError(command: "git " + args.joined(separator: " "), result: result)
        }
        return result
    }

    @discardableResult
    func gh(_ args: [String], in cwd: URL, timeout: TimeInterval = 600) async throws -> CommandResult {
        guard let gh = ghPath else {
            throw CommandError(command: "gh", result: CommandResult(exitCode: 127, stdout: "", stderr: "gh CLI not found"))
        }
        return try await run(launchPath: gh, args: args, cwd: cwd, timeout: timeout)
    }

    private func run(launchPath: String, args: [String], cwd: URL, timeout: TimeInterval) async throws -> CommandResult {
        // A caller cancelled before we even spawned (superseded scan, closed
        // window) shouldn't burn a subprocess.
        try Task.checkCancellation()
        let env = environment()
        let process = Process()
        // Cancellation-aware: a cancelled caller terminates the child instead of
        // leaving git/clone running to completion.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                process.currentDirectoryURL = cwd
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Drain both pipes concurrently so a large stream on one side cannot
                // deadlock against a full 64KB buffer on the other. The lock makes
                // the timed-out snapshot below safe against a late-finishing drain.
                final class Buffers: @unchecked Sendable {
                    private let lock = NSLock()
                    private var out = Data()
                    private var err = Data()
                    func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
                    func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
                    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
                }
                let buffers = Buffers()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    buffers.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    buffers.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }

                let resumed = ResumeOnce()
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                process.terminationHandler = { proc in
                    watchdog.cancel()
                    // Bounded wait: a grandchild (e.g. a stuck credential helper)
                    // that inherited our pipes can hold them open past git's exit.
                    // If EOF never comes, the output is UNTRUSTWORTHY — synthesize
                    // a failure exit so no caller (least of all the verify gate)
                    // mistakes truncated-empty output for a clean success.
                    let drained = group.wait(timeout: .now() + 10) == .success
                    let (out, err) = buffers.snapshot()
                    let exitCode: Int32
                    if drained {
                        exitCode = proc.terminationStatus
                    } else {
                        exitCode = proc.terminationStatus != 0 ? proc.terminationStatus : 124
                    }
                    let result = CommandResult(
                        exitCode: exitCode,
                        stdout: String(decoding: out, as: UTF8.self),
                        stderr: String(decoding: err, as: UTF8.self)
                    )
                    resumed.fire { continuation.resume(returning: result) }
                }

                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                } catch {
                    watchdog.cancel()
                    resumed.fire { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Guards a CheckedContinuation against being resumed more than once.
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire(_ block: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { block() }
    }
}
