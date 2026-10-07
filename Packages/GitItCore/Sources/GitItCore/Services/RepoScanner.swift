import Foundation

/// Finds git repositories below a root folder, up to a maximum depth.
public enum RepoScanner {
    static let skippedNames: Set<String> = [
        "node_modules", ".build", "build", "DerivedData", "Pods", "vendor", ".venv", "venv",
        "target", "dist", "Library", "Applications",
    ]

    /// Returns repository roots. A folder with a `.git` directory is a repository and is not descended
    /// into; a `.git` *file* marks a linked worktree or submodule, which belongs to another repository.
    public static func scan(root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []

        func visit(_ dir: URL, depth: Int) {
            var isDir: ObjCBool = false
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { found.append(dir.standardizedFileURL) }
                return
            }
            guard depth < maxDepth else { return }
            let children = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            for child in children {
                guard !skippedNames.contains(child.lastPathComponent),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                visit(child, depth: depth + 1)
            }
        }

        visit(root.standardizedFileURL, depth: 0)
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
