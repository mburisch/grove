import Foundation

/// Writes every git run and repository operation, with timings, to a JSON Lines file (one per app
/// session) while the Debug log setting is on. Each line is an object with `event` and `t`,
/// seconds since the session started. Safe to use from any thread.
public final class DebugLog: @unchecked Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Grove", isDirectory: true)
    }

    public let directory: URL
    public let fileURL: URL
    public let start: Date
    private let lock = NSLock()
    private var handle: FileHandle?

    public init(directory: URL = DebugLog.defaultDirectory, start: Date = .now) throws {
        self.directory = directory
        self.start = start
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = directory.appendingPathComponent("debug-\(formatter.string(from: start))-\(getpid()).jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        log("session", ["started": ISO8601DateFormatter().string(from: start)])
    }

    deinit { close() }

    /// Stops writing; later calls are ignored.
    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    /// Seconds since the session started, rounded to milliseconds.
    public func offset(_ date: Date) -> Double {
        (date.timeIntervalSince(start) * 1000).rounded() / 1000
    }

    public func log(_ event: String, _ fields: [String: any Sendable] = [:]) {
        var object: [String: Any] = fields
        object["event"] = event
        object["t"] = offset(.now)
        guard JSONSerialization.isValidJSONObject(object),
              var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.withLock { try? handle?.write(contentsOf: line) }
    }

    /// One finished git or gh run: when it was requested, how long it waited for a slot and ran,
    /// and how much it printed.
    public func log(_ run: GitRunRecord) {
        guard let finished = run.finished else { return }
        let queued = run.queued ?? run.started
        var fields: [String: any Sendable] = [
            "tool": run.tool,
            "args": run.arguments,
            "queued": offset(queued),
            "started": offset(run.started),
            "finished": offset(finished),
            "wait": offset(run.started) - offset(queued),
            "duration": offset(finished) - offset(run.started),
            "outBytes": run.stdoutBytes,
            "outLines": run.stdoutLines,
        ]
        if let directory = run.directory { fields["dir"] = directory }
        if let operation = run.operation { fields["op"] = operation }
        if let exitCode = run.exitCode { fields["exit"] = Int(exitCode) }
        if let failure = run.failure { fields["failure"] = failure }
        if run.failureExpected { fields["failureExpected"] = true }
        if !run.stderr.isEmpty { fields["stderr"] = String(run.stderr.prefix(300)) }
        log("git", fields)
    }

    /// Log files in `directory`, oldest first.
    public static func files(in directory: URL = defaultDirectory) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("debug-") && $0.hasSuffix(".jsonl") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Deletes every log file in `directory` and returns how many were deleted.
    @discardableResult
    public static func clear(in directory: URL = defaultDirectory) -> Int {
        files(in: directory).filter { (try? FileManager.default.removeItem(at: $0)) != nil }.count
    }
}
