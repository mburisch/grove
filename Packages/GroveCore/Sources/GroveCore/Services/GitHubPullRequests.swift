import Foundation

/// The pull request shown for a branch.
public struct PullRequestInfo: Sendable, Hashable {
    public enum State: String, Sendable {
        case open, draft, merged, closed
    }

    public var number: Int
    public var title: String
    public var state: State
    public var url: URL

    public init(number: Int, title: String, state: State, url: URL) {
        self.number = number
        self.title = title
        self.state = state
        self.url = url
    }
}

/// Looks up pull requests for local branches with the GitHub CLI (`gh`), using its login.
///
/// Asks GitHub about each branch by name (one aliased GraphQL field per branch) instead of listing
/// the repository's pull requests, so the cost depends on the number of local branches, not on how
/// many pull requests the repository has.
public enum GitHubPullRequests {
    /// Branches asked about per request.
    public static let batchSize = 50
    /// Pull requests read per branch; several when forks used the same branch name.
    static let perBranch = 10

    /// Where `gh` is installed, if it is.
    public static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The GraphQL query for `branches`: field `b<i>` asks about the branch in variable `$h<i>`.
    /// Branch names are only ever passed as variables.
    public static func query(branchCount: Int) -> String {
        let declarations = (0..<branchCount).map { ", $h\($0): String!" }.joined()
        let fields = (0..<branchCount).map { i in
            "b\(i): pullRequests(headRefName: $h\(i), first: \(perBranch), orderBy: {field: UPDATED_AT, direction: DESC}) "
                + "{ nodes { number title state isDraft url headRepositoryOwner { login } } }"
        }
        return "query($owner: String!, $name: String!\(declarations)) { repository(owner: $owner, name: $name) { "
            + fields.joined(separator: " ") + " } }"
    }

    /// The request body for `gh api graphql --input -`.
    public static func requestBody(repo: GitHubRepo, branches: [String]) throws -> Data {
        var variables = ["owner": repo.owner, "name": repo.name]
        for (i, branch) in branches.enumerated() { variables["h\(i)"] = branch }
        return try JSONSerialization.data(withJSONObject: ["query": query(branchCount: branches.count), "variables": variables])
    }

    /// Reads a response to `query`. Pull requests from forks (another head owner) are ignored; for
    /// each branch an open or draft one wins, otherwise the most recently updated.
    public static func parse(_ json: Data, branches: [String], owner: String) -> [String: PullRequestInfo] {
        guard let root = try? JSONDecoder().decode(Response.self, from: json),
              let repository = root.data?.repository else { return [:] }
        var result: [String: PullRequestInfo] = [:]
        for (i, branch) in branches.enumerated() {
            let candidates = (repository["b\(i)"]?.nodes ?? []).compactMap { node -> PullRequestInfo? in
                guard node.headRepositoryOwner?.login.lowercased() == owner.lowercased(),
                      let url = URL(string: node.url) else { return nil }
                let state: PullRequestInfo.State = switch node.state {
                case "MERGED": .merged
                case "CLOSED": .closed
                default: node.isDraft ? .draft : .open
                }
                return PullRequestInfo(number: node.number, title: node.title, state: state, url: url)
            }
            if let pr = candidates.first(where: { $0.state == .open || $0.state == .draft }) ?? candidates.first {
                result[branch] = pr
            }
        }
        return result
    }

    /// Pull requests for `branches` of `repo`, keyed by branch name; branches without one are absent.
    /// Throws if `gh` fails (not logged in, offline, no access). Such failures are expected, so
    /// they aren't flagged as problems in the output log. `directory` only labels the run.
    public static func fetch(repo: GitHubRepo, branches: [String], gh: GitRunner, in directory: URL? = nil) async throws -> [String: PullRequestInfo] {
        var result: [String: PullRequestInfo] = [:]
        var start = 0
        while start < branches.count {
            let batch = Array(branches[start..<min(start + batchSize, branches.count)])
            let arguments = ["api", "graphql", "--input", "-"]
            let output = try await gh.run(arguments, in: directory, timeout: .seconds(60), check: false,
                                          input: requestBody(repo: repo, branches: batch))
            guard output.exitCode == 0 else {
                throw GitError(arguments: arguments, exitCode: output.exitCode, stderr: output.stderr)
            }
            result.merge(parse(Data(output.stdout.utf8), branches: batch, owner: repo.owner)) { $1 }
            start += batchSize
        }
        return result
    }

    private struct Response: Decodable {
        var data: DataField?
        struct DataField: Decodable { var repository: [String: Connection]? }
        struct Connection: Decodable { var nodes: [Node] }
        struct Node: Decodable {
            var number: Int
            var title: String
            var state: String
            var isDraft: Bool
            var url: String
            var headRepositoryOwner: Owner?
        }
        struct Owner: Decodable { var login: String }
    }
}
