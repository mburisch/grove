import CryptoKit
import Foundation

/// Keeps each repository's last snapshot on disk, so the app can show it right after launch while
/// the first refresh (slow in big repositories) runs. One JSON file per repository; a file from an
/// older format, or one that can't be read, is ignored. Safe to use from any thread.
public struct SnapshotStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/Snapshots", isDirectory: true)
    }

    /// Bumped when `RepoSnapshot` changes shape, so older files are ignored instead of misread.
    static let formatVersion = 1

    private struct Stored: Codable {
        var version: Int
        var path: String
        var saved: Date
        var snapshot: RepoSnapshot
    }

    public let directory: URL

    public init(directory: URL = SnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    /// The file for `repoPath`, named by a hash of the path.
    func fileURL(for repoPath: String) -> URL {
        let digest = SHA256.hash(data: Data(repoPath.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    public func save(_ snapshot: RepoSnapshot, for repoPath: String, at date: Date = .now) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(version: Self.formatVersion, path: repoPath, saved: date, snapshot: snapshot))
        try data.write(to: fileURL(for: repoPath), options: .atomic)
    }

    /// The saved snapshot of `repoPath` and when it was taken, if there is a readable one.
    public func load(for repoPath: String) -> (snapshot: RepoSnapshot, saved: Date)? {
        guard let data = try? Data(contentsOf: fileURL(for: repoPath)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.formatVersion, stored.path == repoPath else { return nil }
        return (stored.snapshot, stored.saved)
    }

    public func remove(for repoPath: String) {
        try? FileManager.default.removeItem(at: fileURL(for: repoPath))
    }
}
