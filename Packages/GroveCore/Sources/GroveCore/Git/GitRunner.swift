import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String
    public var timedOut: Bool = false

    public var errorDescription: String? {
        if timedOut { return "git \(arguments.first ?? "") timed out" }
        let message = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
            .last ?? "exit code \(exitCode)"
        return "git \(arguments.first ?? ""): \(message)"
    }
}

public struct GitResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
}

/// Runs the git CLI. Stateless and safe to share; each call spawns its own process.
public struct GitRunner: Sendable {
    public var gitPath: String

    public init(gitPath: String = GitRunner.defaultGitPath) {
        self.gitPath = gitPath
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

        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            stderrBuffer.append(data)
            if let onStderr, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                onStderr(text)
            }
        }

        let timedOut = Flag()
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let stdinPipe, let input {
                    // Written off the caller's thread so a large input can't block on a full pipe.
                    Task.detached {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }
                let pid = process
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if pid.isRunning {
                        timedOut.set()
                        pid.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything left after the handlers were removed.
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let result = GitResult(
            stdout: stdoutBuffer.string,
            stderr: stderrBuffer.string,
            exitCode: exitCode
        )
        if timedOut.isSet {
            throw GitError(arguments: arguments, exitCode: exitCode, stderr: result.stderr, timedOut: true)
        }
        try Task.checkCancellation()
        if check && exitCode != 0 {
            throw GitError(arguments: arguments, exitCode: exitCode, stderr: result.stderr)
        }
        return result
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
