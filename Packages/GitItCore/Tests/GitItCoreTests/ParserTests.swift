import Foundation
import Testing
@testable import GitItCore

struct ParserTests {
    @Test func refs() {
        let line = ["refs/heads/main", "abc123", "origin/main", "ahead 1, behind 2", "Fix it", "Ann", "1700000000", "/tmp/wt", ""]
            .joined(separator: "\0")
        let symref = ["refs/remotes/origin/HEAD", "abc123", "", "", "s", "a", "1700000000", "", "refs/remotes/origin/main"]
            .joined(separator: "\0")
        let refs = GitParsers.parseRefs(line + "\n" + symref + "\n")
        #expect(refs.count == 2)
        #expect(refs[0].upstream == "origin/main")
        #expect(refs[0].worktreePath == "/tmp/wt")
        #expect(refs[0].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!refs[0].isSymref)
        #expect(refs[1].isSymref)
    }

    @Test func track() {
        #expect(GitParsers.parseTrack("") == .zero)
        #expect(GitParsers.parseTrack("ahead 3") == AheadBehind(ahead: 3, behind: 0))
        #expect(GitParsers.parseTrack("behind 4") == AheadBehind(ahead: 0, behind: 4))
        #expect(GitParsers.parseTrack("ahead 1, behind 2") == AheadBehind(ahead: 1, behind: 2))
        #expect(GitParsers.parseTrack("gone") == nil)
    }

    @Test func leftRight() {
        #expect(GitParsers.parseLeftRight("2\t5\n") == AheadBehind(ahead: 2, behind: 5))
        #expect(GitParsers.parseLeftRight("garbage") == nil)
    }

    @Test func worktrees() {
        let output = """
        worktree /repo
        HEAD 1111
        branch refs/heads/main

        worktree /repo-feature
        HEAD 2222
        branch refs/heads/feature/x
        locked

        worktree /gone
        HEAD 3333
        detached
        prunable gitdir file points to non-existent location

        """
        let records = GitParsers.parseWorktrees(output)
        #expect(records.count == 3)
        #expect(records[0].branch == "main")
        #expect(records[1].branch == "feature/x")
        #expect(records[1].isLocked)
        #expect(records[2].branch == nil)
        #expect(records[2].isDetached && records[2].isPrunable)
    }

    @Test func status() {
        let output = """
        # branch.oid 1111
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +1 -3
        1 M. N... 100644 100644 100644 a b staged.txt
        1 .M N... 100644 100644 100644 a b unstaged.txt
        1 MM N... 100644 100644 100644 a b both.txt
        2 R. N... 100644 100644 100644 a b R100 new.txt\told.txt
        u UU N... 100644 100644 100644 100644 a b c conflict.txt
        ? untracked.txt
        """
        let s = GitParsers.parseStatus(output)
        #expect(s.branch == "main")
        #expect(s.upstream == "origin/main")
        #expect(s.aheadBehind == AheadBehind(ahead: 1, behind: 3))
        #expect(s.status == WorkingTreeStatus(staged: 3, unstaged: 2, untracked: 1, conflicted: 1))
        #expect(GitParsers.parseStatus("# branch.head (detached)\n").branch == nil)
    }

    @Test func shortStat() {
        #expect(GitParsers.parseShortStat(" 3 files changed, 10 insertions(+), 2 deletions(-)\n")
                == DiffStat(files: 3, insertions: 10, deletions: 2))
        #expect(GitParsers.parseShortStat(" 1 file changed, 1 deletion(-)") == DiffStat(files: 1, insertions: 0, deletions: 1))
        #expect(GitParsers.parseShortStat("") == .zero)
    }

    @Test func progress() {
        let p = GitParsers.parseProgress("Receiving objects:  50% (5/10), 1.00 MiB | 2 MiB/s")
        #expect(p?.phase == "Receiving objects")
        #expect(abs((p?.fraction ?? 0) - 0.45) < 0.001)
        #expect(GitParsers.parseProgress("Cloning into 'x'...") == nil)

        let splitter = LineSplitter()
        #expect(splitter.feed("Receiving objects:  1%\rReceiving") == ["Receiving objects:  1%"])
        #expect(splitter.feed(" objects:  2%\n") == ["Receiving objects:  2%"])
    }

    @Test func gitHubURLs() {
        let expected = GitHubRepo(owner: "mburisch", name: "localdev")
        for input in [
            "https://github.com/mburisch/localdev.git",
            "https://github.com/mburisch/localdev",
            "https://github.com/mburisch/localdev/tree/main/src",
            "git@github.com:mburisch/localdev.git",
            "ssh://git@github.com/mburisch/localdev.git",
            "github.com/mburisch/localdev",
        ] {
            #expect(GitHubRepo(remoteURL: input) == expected, "\(input)")
        }
        #expect(GitHubRepo(userInput: "mburisch/localdev") == expected)
        #expect(GitHubRepo(remoteURL: "https://gitlab.com/a/b") == nil)

        let browser = CloneSource(input: "https://github.com/mburisch/localdev/tree/main")
        #expect(browser?.url == "https://github.com/mburisch/localdev.git")
        #expect(browser?.suggestedName == "localdev")
        #expect(CloneSource(input: "git@github.com:mburisch/localdev.git")?.url == "git@github.com:mburisch/localdev.git")
        #expect(CloneSource(input: "https://gitlab.com/a/thing.git")?.suggestedName == "thing")
        #expect(CloneSource(input: "hello world") == nil)
    }

    @Test func launcherExpansion() {
        #expect(Launcher.expand("cursor {path}", path: "/a b/it's") == "cursor '/a b/it'\\''s'")
        #expect(Launcher.expand("code", path: "/x") == "code '/x'")
    }

    @Test func configDecodesPartialJSON() throws {
        let json = #"{"repositories": ["/a"], "defaultFetchIntervalMinutes": 5}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.repositories == ["/a"])
        #expect(config.defaultFetchIntervalMinutes == 5)
        #expect(config.launchers == Launcher.defaults)
    }
}
