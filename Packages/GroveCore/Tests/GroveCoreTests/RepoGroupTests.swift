import Foundation
import Testing
@testable import GroveCore

struct RepoGroupTests {
    let paths = ["/a", "/b", "/c", "/d"]

    @Test func sectionsPlaceEachRepoOnceAndDropStalePaths() {
        var config = AppConfig()
        config.groups = [RepoGroup(name: "Apps", repos: ["/c", "/gone", "/a"]), RepoGroup(name: "Empty")]
        config.ungroupedOrder = ["/d"]
        let sections = config.sections(for: paths)
        #expect(sections.map(\.group?.name) == ["Apps", "Empty", nil])
        #expect(sections.map(\.repos) == [["/c", "/a"], [], ["/d", "/b"]])
    }

    @Test func moveBetweenGroupsAndReorder() {
        var config = AppConfig()
        let apps = RepoGroup(name: "Apps")
        config.groups = [apps]
        config.move(repo: "/b", to: apps.id, allPaths: paths)
        config.move(repo: "/d", to: apps.id, before: "/b", allPaths: paths)
        #expect(config.sections(for: paths).map(\.repos) == [["/d", "/b"], ["/a", "/c"]])

        // Back to ungrouped, placed before /a.
        config.move(repo: "/b", to: nil, before: "/a", allPaths: paths)
        #expect(config.sections(for: paths).map(\.repos) == [["/d"], ["/b", "/a", "/c"]])

        // Reorder within ungrouped.
        config.move(repo: "/a", to: nil, allPaths: paths)
        #expect(config.sections(for: paths).map(\.repos) == [["/d"], ["/b", "/c", "/a"]])
    }

    @Test func groupOrderingAndDeletion() throws {
        var config = AppConfig()
        let x = RepoGroup(name: "X", repos: ["/a"]), y = RepoGroup(name: "Y"), z = RepoGroup(name: "Z")
        config.groups = [x, y, z]
        config.move(group: z.id, before: x.id)
        #expect(config.groups.map(\.name) == ["Z", "X", "Y"])
        config.move(group: z.id, before: nil)
        #expect(config.groups.map(\.name) == ["X", "Y", "Z"])
        config.deleteGroup(x.id)
        #expect(config.sections(for: paths).last?.repos == paths)

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.groups == config.groups)
    }
}
