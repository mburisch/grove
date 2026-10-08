import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String
    public var timedOut: Bool = false
    /// Set when git could not be started at all, e.g. "Bad file descriptor (POSIX error 9)".
    public var launchFailure: String?
    /// The output-log entry of the failed run, so the UI can show exactly that output.
    public var runID: UUID?

    /// Tags a fetch refused to update because they moved on the remote, from git's
    /// `! [rejected] latest -> latest (would clobber existing tag)` lines.
    public var clobberedTags: [String] {
        stderr.split(separator: "\n").compactMap { line in
            guard line.contains("(would clobber existing tag)"),
                  let arrow = line.range(of: " -> ") else { return nil }
            return line[arrow.upperBound...].split(separator: " ").first.map(String.init)
        }
    }

    public var errorDescription: String? {
        let command = "git \(arguments.first ?? "")"
        if let launchFailure { return "Couldn't start \(command): \(launchFailure)" }
        if timedOut { return "\(command) timed out" }
        let tags = clobberedTags
        if !tags.isEmpty {
            let names = tags.map { "“\($0)”" }.joined(separator: ", ")
            let (noun, pronoun) = tags.count == 1 ? ("Tag", "it") : ("Tags", "them")
            return "\(noun) \(names) moved on the remote, and git won't overwrite the local copy, so the fetch "
                + "stopped. Update \(pronoun) to the remote's version, or run: git fetch --force --tags"
        }
        let message = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
            .last ?? "exit code \(exitCode)"
        return "\(command): \(message.unescapingUnicode)"
    }
}

public struct GitResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
}

/// One git invocation as shown in the output log. Reported when it starts and again when it ends
/// (same `id`); `finished` is nil while it runs.
public struct GitRunRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The program that ran: "git", or "gh" for GitHub lookups.
    public var tool = "git"
    public var arguments: [String]
    public var directory: String?
    public var started: Date
    public var finished: Date?
    public var exitCode: Int32?
    public var stdout: String = ""
    public var stderr: String = ""
    /// Why the run failed without a normal exit: could not start, timed out or was cancelled.
    public var failure: String?
    /// The caller checks the exit code itself (e.g. an optional lookup that may legitimately fail,
    /// such as a diff against a branch with no merge base), so a non-zero exit is not a problem.
    public var failureExpected = false

    public var isRunning: Bool { finished == nil }
    public var succeeded: Bool { finished != nil && failure == nil && exitCode == 0 }
    /// Failed in a way worth looking at: couldn't start, timed out, or exited non-zero where
    /// that wasn't expected. Cancellation is not a problem.
    public var isProblem: Bool {
        guard finished != nil, failure != "Cancelled" else { return false }
        return failure != nil || (exitCode != 0 && !failureExpected)
    }
    public var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
    public var commandLine: String { ([tool] + arguments).joined(separator: " ") }

    /// True for read-only lookups (status, rev-parse, log, …) that Grove runs to refresh its view,
    /// as opposed to actions like fetch, pull or worktree add.
    public var isQuery: Bool {
        if tool == "gh" { return true }  // Grove only reads from GitHub.
        let subcommand = arguments.first { !$0.hasPrefix("-") } ?? ""
        switch subcommand {
        case "status", "rev-parse", "for-each-ref", "log", "rev-list", "diff", "show", "ls-files",
             "cat-file", "symbolic-ref", "merge-base", "describe", "count-objects", "ls-remote", "":
            return true
        case "config":
            return !arguments.contains { ["--add", "--unset", "--unset-all", "--replace-all"].contains($0) }
                && arguments.filter { !$0.hasPrefix("-") }.count <= 2
        case "worktree", "remote", "branch":
            return arguments.count == 1 || arguments.contains { ["list", "-v", "--list", "--show-current", "get-url"].contains($0) }
        default:
            return false
        }
    }
}

/// Runs the git CLI. Stateless and safe to share; each call spawns its own process.
public struct GitRunner: Sendable {
    public var gitPath: String
    /// Name shown for this runner's runs in the output log; the runner can also run `gh`.
    public var tool: String
    /// Shared cap on concurrent git processes; nil runs without a limit.
    public var limiter: GitLimiter?
    /// Receives every run when it starts and when it ends, for the output log.
    public var onRecord: (@Sendable (GitRunRecord) -> Void)?

    public init(
        gitPath: String = GitRunner.defaultGitPath,
        tool: String = "git",
        limiter: GitLimiter? = nil,
        onRecord: (@Sendable (GitRunRecord) -> Void)? = nil
    ) {
        self.gitPath = gitPath
        self.tool = tool
        self.limiter = limiter
        self.onRecord = onRecord
    }

    public static var defaultGitPath: String {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }

    /// Environment for non-interactive git: never prompt for credentials, stable output,
    /// and a PATH that finds credential helpers (e.g. `gh auth git-credential`) from a GUI app.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (existing + extraPath.filter { !existing.contains($0) }).joined(separator: ":")
        return env
    }()

    /// How often a start that fails with a transient error (EBADF, EAGAIN, EINTR) is tried.
    private static let launchAttempts = 3

    /// Runs git and returns its output, throwing `GitError` on a non-zero exit (unless `check` is false).
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: Duration = .seconds(300),
        check: Bool = true,
        input: Data? = nil,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> GitResult {
        guard let limiter else {
            return try await recorded(arguments, in: directory, timeout: timeout, check: check, input: input, onStderr: onStderr)
        }
        // The timeout starts once a slot is free, so waiting in the queue never times a run out.
        return try await limiter.withSlot {
            try await recorded(arguments, in: directory, timeout: timeout, check: check, input: input, onStderr: onStderr)
        }
    }

    /// Runs git, retrying transient start failures, and reports the run to `onRecord`.
    private func recorded(
        _ arguments: [String],
        in directory: URL?,
        timeout: Duration,
        check: Bool,
        input: Data?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> GitResult {
        var record = GitRunRecord(id: UUID(), tool: tool, arguments: arguments, directory: directory?.path, started: .now)
        record.failureExpected = !check
        onRecord?(record)
        var outcome: Result<Outcome, Error>
        var attempt = 1
        while true {
            do {
                outcome = .success(try await launch(arguments, in: directory, timeout: timeout, input: input, onStderr: onStderr))
            } catch let failure as LaunchFailure where failure.isTransient && attempt < Self.launchAttempts {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(100 * attempt))
                continue
            } catch {
                outcome = .failure(error)
            }
            break
        }

        record.finished = .now
        let result: GitResult
        switch outcome {
        case .success(let run):
            result = run.result
            record.exitCode = result.exitCode
            record.stdout = Self.clipped(result.stdout)
            record.stderr = Self.clipped(result.stderr)
            if run.timedOut { record.failure = "Timed out after \(timeout)" }
            if attempt > 1 { record.stderr = "(started on attempt \(attempt))\n" + record.stderr }
        case .failure(let error as LaunchFailure):
            record.failure = "Couldn't start \(tool) (\(attempt) attempts): \(error.message)"
            onRecord?(record)
            throw GitError(arguments: arguments, exitCode: -1, stderr: "", launchFailure: error.message, runID: record.id)
        case .failure(let error):
            record.failure = error is CancellationError ? "Cancelled" : "\(error)"
            onRecord?(record)
            throw error
        }
        if Task.isCancelled && record.failure == nil { record.failure = "Cancelled" }
        onRecord?(record)

        if case .success(let run) = outcome, run.timedOut {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr, timedOut: true, runID: record.id)
        }
        try Task.checkCancellation()
        if check && result.exitCode != 0 {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr, runID: record.id)
        }
        return result
    }

    fileprivate struct Outcome {
        var result: GitResult
        var timedOut: Bool
    }

    /// `Process.run()` failed; git never started.
    private struct LaunchFailure: Error {
        var error: NSError

        var isTransient: Bool {
            error.domain == NSPOSIXErrorDomain && [EBADF, EAGAIN, EINTR].contains(Int32(error.code))
        }

        var message: String {
            let reason = (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String)
                ?? error.localizedDescription.unescapingUnicode
            return "\(reason) (\(error.domain) \(error.code))"
        }
    }

    /// Starts one git process and collects its output. Output is read with blocking reads on
    /// background threads until EOF, which avoids `FileHandle.readabilityHandler` and its
    /// dispatch sources.
    private func launch(
        _ arguments: [String],
        in directory: URL?,
        timeout: Duration,
        input: Data?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.environment = Self.environment
        if let directory { process.currentDirectoryURL = directory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = input.map { _ in Pipe() }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        // Close every pipe end as soon as the run is over instead of whenever the objects are
        // freed: anything still holding the Process (or a Pipe) would otherwise keep descriptors
        // open, and a GUI app runs out of them (256 by default), after which git can't be started
        // at all ("Bad file descriptor").
        defer {
            for pipe in [stdoutPipe, stderrPipe] + (stdinPipe.map { [$0] } ?? []) {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }

        let timedOut = Flag()
        let readers = Readers()
        // Ends the timeout task once git exits so it doesn't keep the Process alive.
        defer { readers.timeout?.cancel() }
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: LaunchFailure(error: error as NSError))
                    return
                }
                // Started right away so a child writing more than a pipe buffer never blocks.
                readers.stdout = StreamReader(stdoutPipe.fileHandleForReading)
                readers.stderr = StreamReader(stderrPipe.fileHandleForReading) { data in
                    if let onStderr, let text = String(data: data, encoding: .utf8) { onStderr(text) }
                }
                if let stdinPipe, let input {
                    // Written off the caller's thread so a large input can't block on a full pipe.
                    DispatchQueue.global().async {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }
                readers.timeout = Task.detached { [weak process] in
                    guard (try? await Task.sleep(for: timeout)) != nil, let process else { return }
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // The child has exited; collect the rest of its output up to EOF.
        let stdout = await readers.stdout?.finish() ?? ""
        let stderr = await readers.stderr?.finish() ?? ""
        return Outcome(result: GitResult(stdout: stdout, stderr: stderr, exitCode: exitCode), timedOut: timedOut.isSet)
    }

    /// Keeps the log small: the last 32 KB of a stream.
    private static func clipped(_ text: String) -> String {
        let limit = 32_000
        guard text.utf8.count > limit else { return text }
        return "…\n" + String(decoding: text.utf8.suffix(limit), as: UTF8.self)
    }

    /// Convenience: run in a repository and return trimmed stdout.
    public func output(_ arguments: [String], in directory: URL, timeout: Duration = .seconds(60)) async throws -> String {
        try await run(arguments, in: directory, timeout: timeout).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run and return trimmed stdout, or nil on failure.
    public func outputIfSuccess(_ arguments: [String], in directory: URL) async -> String? {
        guard let result = try? await run(arguments, in: directory, timeout: .seconds(60), check: false),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads a pipe until EOF on a background thread with blocking reads.
private final class StreamReader: @unchecked Sendable {
    private let buffer = DataBuffer()
    private let done = DispatchGroup()

    init(_ handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
        done.enter()
        DispatchQueue.global(qos: .utility).async { [buffer, done] in
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                buffer.append(chunk)
                onChunk?(chunk)
            }
            done.leave()
        }
    }

    /// Waits for EOF and returns everything read.
    func finish() async -> String {
        await withCheckedContinuation { continuation in
            done.notify(queue: .global()) { continuation.resume() }
        }
        return buffer.string
    }
}

/// The readers and timeout of one run, created once the process has started.
private final class Readers: @unchecked Sendable {
    var stdout: StreamReader?
    var stderr: StreamReader?
    var timeout: Task<Void, Never>?
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

extension String {
    /// Turns `\U2019`-style escapes, as found in printed `NSError`/`NSDictionary` descriptions,
    /// back into the characters they stand for.
    public var unescapingUnicode: String {
        guard contains("\\U") || contains("\\u") else { return self }
        var result = ""
        var rest = self[...]
        while let escape = rest.range(of: #"\\[Uu][0-9A-Fa-f]{4}"#, options: .regularExpression) {
            result += rest[..<escape.lowerBound]
            if let scalar = UInt32(rest[escape].dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[escape]
            }
            rest = rest[escape.upperBound...]
        }
        return result + rest
    }
}
