import Foundation
import Testing
@testable import GroveCore

@Suite struct PullRequestTests {
    @Test func queryAliasesEachBranch() throws {
        let query = GitHubPullRequests.query(branchCount: 3)
        #expect(query.contains("$h0: String!, $h1: String!, $h2: String!"))
        #expect(query.contains("b2: pullRequests(headRefName: $h2"))
        #expect(!query.contains("b3:"))

        // Branch names travel as variables, never inside the query text.
        let body = try GitHubPullRequests.requestBody(repo: GitHubRepo(owner: "o", name: "r"), branches: ["a\"b", "c"])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: String])
        #expect(variables == ["owner": "o", "name": "r", "h0": "a\"b", "h1": "c"])
        #expect(!(json["query"] as? String ?? "").contains("a\"b"))
    }

    @Test func parsesAndFiltersForks() {
        func node(_ number: Int, _ state: String, draft: Bool = false, owner: String = "me") -> String {
            """
            {"number":\(number),"title":"PR \(number)","state":"\(state)","isDraft":\(draft),
             "url":"https://github.com/me/repo/pull/\(number)","headRepositoryOwner":{"login":"\(owner)"}}
            """
        }
        let json = """
        {"data":{"repository":{
          "b0":{"nodes":[\(node(9, "CLOSED")), \(node(7, "OPEN"))]},
          "b1":{"nodes":[\(node(5, "OPEN", owner: "someone")), \(node(4, "MERGED", owner: "ME"))]},
          "b2":{"nodes":[\(node(3, "OPEN", draft: true))]},
          "b3":{"nodes":[\(node(2, "OPEN", owner: "fork"))]},
          "b4":{"nodes":[]}
        }}}
        """
        let prs = GitHubPullRequests.parse(Data(json.utf8), branches: ["feature", "done", "wip", "forked", "none"], owner: "me")
        #expect(prs["feature"]?.number == 7)  // Open wins over a more recently updated closed one.
        #expect(prs["feature"]?.state == .open)
        #expect(prs["done"]?.number == 4)  // The fork's PR is ignored; owner matches ignoring case.
        #expect(prs["done"]?.state == .merged)
        #expect(prs["wip"]?.state == .draft)
        #expect(prs["forked"] == nil)
        #expect(prs["none"] == nil)
        #expect(prs["feature"]?.url.absoluteString == "https://github.com/me/repo/pull/7")
    }

    @Test func unreadableResponsesGiveNothing() {
        #expect(GitHubPullRequests.parse(Data("not json".utf8), branches: ["a"], owner: "me").isEmpty)
        #expect(GitHubPullRequests.parse(Data(#"{"data":{"repository":null}}"#.utf8), branches: ["a"], owner: "me").isEmpty)
    }
}
