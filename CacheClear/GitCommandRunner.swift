//
//  GitCommandRunner.swift
//  CacheClear
//
//  The single choke point for spawning `git` and `gh`. Builds an explicit
//  environment so credentials resolve even though the app launches from the GUI
//  (where PATH is minimal and `~/.gitconfig` has no credential helper wired).
//

import Foundation

struct CommandResult: Sendable {
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

struct CommandError: Error, LocalizedError {
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
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i \(home)/.ssh/id_rsa"
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

    /// On-disk size of a directory via `du -sk`, in bytes. Returns 0 on failure.
    func diskUsageBytes(_ path: String) async -> UInt64 {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard let r = try? await run(launchPath: "/usr/bin/du", args: ["-sk", path], cwd: parent, timeout: 180),
              r.ok else { return 0 }
        let field = r.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? "0"
        return (UInt64(field) ?? 0) * 1024
    }

    private func run(launchPath: String, args: [String], cwd: URL, timeout: TimeInterval) async throws -> CommandResult {
        let env = environment()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
            process.currentDirectoryURL = cwd
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain both pipes concurrently so a large stream on one side cannot
            // deadlock against a full 64KB buffer on the other.
            final class Buffers: @unchecked Sendable { var out = Data(); var err = Data() }
            let buffers = Buffers()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffers.out = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffers.err = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            let resumed = ResumeOnce()
            process.terminationHandler = { proc in
                group.wait()
                let result = CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: buffers.out, as: UTF8.self),
                    stderr: String(decoding: buffers.err, as: UTF8.self)
                )
                resumed.fire { continuation.resume(returning: result) }
            }

            do {
                try process.run()
            } catch {
                resumed.fire { continuation.resume(throwing: error) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Guards a CheckedContinuation against being resumed more than once.
private final class ResumeOnce: @unchecked Sendable {
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
