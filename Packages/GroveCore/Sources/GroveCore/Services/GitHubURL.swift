import Foundation

/// A GitHub `owner/repo` pair parsed from a remote URL, a browser URL, or shorthand.
public struct GitHubRepo: Sendable, Hashable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var slug: String { "\(owner)/\(name)" }
    public var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    public var httpsCloneURL: String { "https://github.com/\(owner)/\(name).git" }

    /// Parses remote URLs and pasted links:
    /// `https://github.com/o/r(.git)`, `https://github.com/o/r/tree/main/...`,
    /// `git@github.com:o/r.git`, `ssh://git@github.com/o/r.git`, `github.com/o/r`.
    public init?(remoteURL raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let path: String
        if let range = text.range(of: "git@github.com:") ?? text.range(of: "github.com:") {
            path = String(text[range.upperBound...])
        } else {
            if !text.contains("://") { text = "https://" + text }
            guard let url = URL(string: text), let host = url.host?.lowercased(),
                  host == "github.com" || host == "www.github.com" else { return nil }
            path = url.path
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard Self.isValidComponent(parts[0]), Self.isValidComponent(repo) else { return nil }
        self.owner = parts[0]
        self.name = repo
    }

    /// Like `init(remoteURL:)` but also accepts bare `owner/repo` shorthand.
    public init?(userInput raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = GitHubRepo(remoteURL: text) {
            self = parsed
            return
        }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count == 2, !text.contains(":"),
              Self.isValidComponent(parts[0]), Self.isValidComponent(parts[1]) else { return nil }
        self.owner = parts[0]
        self.name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
    }

    private static func isValidComponent(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }
}

/// What the clone dialog should pass to `git clone` for pasted text.
public struct CloneSource: Sendable, Hashable {
    public var url: String
    public var suggestedName: String
    public var gitHub: GitHubRepo?

    /// Accepts GitHub links/shorthand, and any other git URL (passed through unchanged).
    public init?(input raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        if let gh = GitHubRepo(userInput: text) {
            gitHub = gh
            suggestedName = gh.name
            // Keep SSH remotes as SSH; normalize browser links (e.g. /tree/main) to a clone URL.
            if text.hasPrefix("git@") || text.hasPrefix("ssh://") {
                url = text
            } else {
                url = gh.httpsCloneURL
            }
            return
        }

        let looksLikeURL = text.contains("://") || text.contains("@") || text.hasPrefix("/")
        guard looksLikeURL else { return nil }
        url = text
        var last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repo"
        if last.hasSuffix(".git") { last.removeLast(4) }
        suggestedName = last.isEmpty ? "repo" : last
        gitHub = nil
    }
}
