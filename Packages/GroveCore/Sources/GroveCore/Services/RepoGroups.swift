import Foundation

/// A named, user-ordered set of repositories shown as a section in the repo list.
public struct RepoGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Repository paths in display order.
    public var repos: [String]
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, repos: [String] = [], collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.repos = repos
        self.collapsed = collapsed
    }
}

/// One section of the repo list: a group, or the ungrouped repos (`group == nil`).
public struct RepoSection: Sendable, Hashable {
    public var group: RepoGroup?
    public var repos: [String]
}

public extension AppConfig {
    /// Groups in order, then the ungrouped repos. `paths` is the known repos in their default order;
    /// stale paths stored in groups are dropped and each repo appears exactly once.
    func sections(for paths: [String]) -> [RepoSection] {
        let known = Set(paths)
        var placed = Set<String>()
        var result: [RepoSection] = []
        for group in groups {
            let members = group.repos.filter { known.contains($0) && placed.insert($0).inserted }
            result.append(RepoSection(group: group, repos: members))
        }
        let rank = Dictionary(ungroupedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let rest = paths.enumerated()
            .filter { !placed.contains($0.element) }
            .sorted { (rank[$0.element] ?? Int.max, $0.offset) < (rank[$1.element] ?? Int.max, $1.offset) }
            .map(\.element)
        result.append(RepoSection(group: nil, repos: rest))
        return result
    }

    /// Moves a repo into `group` (nil = ungrouped), before `before` or at the end.
    mutating func move(repo path: String, to group: RepoGroup.ID?, before: String? = nil, allPaths: [String]) {
        guard path != before else { return }
        var target = sections(for: allPaths).first { $0.group?.id == group }?.repos ?? []
        target.removeAll { $0 == path }
        let index = before.flatMap { target.firstIndex(of: $0) } ?? target.endIndex
        target.insert(path, at: index)

        for i in groups.indices { groups[i].repos.removeAll { $0 == path } }
        if let group, let i = groups.firstIndex(where: { $0.id == group }) {
            groups[i].repos = target
        } else {
            ungroupedOrder = target
        }
    }

    /// Moves a group before another group, or to the end.
    mutating func move(group id: RepoGroup.ID, before: RepoGroup.ID?) {
        guard id != before, let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        let index = before.flatMap { b in groups.firstIndex { $0.id == b } } ?? groups.endIndex
        groups.insert(group, at: index)
    }

    /// Deletes a group; its repos become ungrouped.
    mutating func deleteGroup(_ id: RepoGroup.ID) {
        groups.removeAll { $0.id == id }
    }

    /// Forgets a repo everywhere it is ordered.
    mutating func forgetOrdering(of path: String) {
        for i in groups.indices { groups[i].repos.removeAll { $0 == path } }
        ungroupedOrder.removeAll { $0 == path }
    }

    /// Repository paths the config still remembers (added, hidden, grouped, ordered or with
    /// settings) whose folders no longer exist, sorted. Kept until forgotten so a repo on an
    /// unmounted drive comes back with its group and settings.
    func missingRepositories(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        let remembered = repositories + excluded + Array(repoSettings.keys)
            + groups.flatMap(\.repos) + ungroupedOrder
        return Set(remembered).filter { !exists($0) }.sorted()
    }

    /// Removes every trace of a repository path from the config.
    mutating func forget(repository path: String) {
        repositories.removeAll { $0 == path }
        excluded.removeAll { $0 == path }
        repoSettings[path] = nil
        forgetOrdering(of: path)
    }
}
