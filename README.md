# Grove

A macOS menu bar app that keeps an eye on your local git checkouts: what's ahead or behind, what's uncommitted, and which worktrees exist, without opening a terminal for each repo.

## Features

- **Repository list** of folders you add directly or scan for (repos found below a root folder, up to a set depth), organized into groups you can reorder by drag and drop.
- **Status at a glance**: ahead/behind counts against upstream, staged, modified, untracked and conflicted files.
- **Worktree inspector**: every worktree of a repo with its branch, upstream, comparison to the primary branch, HEAD commit and changed files. Missing (prunable) and locked worktrees are flagged.
- **Fetch and pull**: per repo, per group, or all at once, with optional automatic fetching on a global or per-repo interval. Pulls are fast-forward only.
- **Clone** from a URL or `owner/repo` as a full, shallow or blobless checkout, and convert existing repos between those modes.
- **Shortcuts**: reveal in Finder, open on GitHub, copy path, and custom "open with" actions (an app or a shell command).

Grove runs the `git` command-line tool, so authentication works the same as in your terminal, including credential helpers like `gh auth git-credential`. It never prompts for credentials itself.

## Requirements

- macOS 27 or later
- git, from the Xcode Command Line Tools or Homebrew

## Building from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/mburisch/grove.git
cd grove
xcodegen generate
open Grove.xcodeproj
```

The Xcode project is generated from `project.yml` and isn't checked in; run `xcodegen generate` again after changing `project.yml`.

Run the core tests with:

```sh
swift test --package-path Packages/GroveCore
```

## Releasing

`scripts/release.sh` builds a Developer ID signed and notarized `Grove.app` and zips it into `dist/`. See the comment at the top of the script for the one-time certificate and notarization setup.

## License

[MIT](LICENSE)
