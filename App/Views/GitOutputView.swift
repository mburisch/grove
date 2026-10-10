import GroveCore
import SwiftUI

/// The git commands Grove ran, newest first, with what each one printed.
struct GitOutputView: View {
    @Environment(AppModel.self) private var model
    enum Kind { case all, actions, problems }
    @State private var kind = Kind.all
    @State private var search = ""
    @State private var selection: GitRunRecord.ID?

    var body: some View {
        @Bindable var model = model
        let records = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $kind) {
                    Text("All").tag(Kind.all)
                    Text("Actions").tag(Kind.actions)
                    Text("Problems \(model.gitLog.records.count(where: \.isProblem))").tag(Kind.problems)
                }
                .help("Actions hides the status and branch lookups Grove runs to refresh its view")
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let path = model.gitLogRepo {
                    HStack(spacing: 4) {
                        Text(model.repo(at: path)?.name ?? URL(fileURLWithPath: path).lastPathComponent)
                        Button { model.gitLogRepo = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Show all repositories")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                TextField("Search commands and output", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text("\(records.count) of \(model.gitLog.records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") { model.gitLog.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(batches(records)) { batch in
                        Section {
                            ForEach(batch.records) { record in
                                RunRow(record: record, repoName: repoName(for: record))
                                    .tag(record.id)
                            }
                        } header: {
                            BatchHeader(batch: batch, repositories: Set(batch.records.compactMap(repoName(for:))).count)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity)
                Divider()
                Group {
                    if let record = records.first(where: { $0.id == selection }) {
                        RunDetail(record: record)
                    } else {
                        Text(placeholder(empty: records.isEmpty))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 460)
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            // Opened from a repo: show its latest action (or latest failure) right away, falling
            // back to its latest run of any kind.
            let finished = records.filter { !$0.isRunning }
            switch model.gitLogFocus {
            case .run(let id):
                // Drop the repo filter if the run happened in a folder it doesn't cover.
                if !records.contains(where: { $0.id == id }) { model.gitLogRepo = nil }
                selection = id
            case .latestProblem: selection = (finished.first(where: \.isProblem) ?? finished.first)?.id
            case .latestAction: selection = (finished.first { !$0.isQuery } ?? finished.first)?.id
            case nil: break
            }
            model.gitLogFocus = nil
        }
    }

    private func placeholder(empty: Bool) -> String {
        guard empty else { return "Select a command to see its output." }
        if model.gitLog.records.isEmpty {
            return "No git commands yet. The log only covers the time since Grove started."
        }
        return "No commands match. Clear the filters above to see all of them."
    }

    private var filtered: [GitRunRecord] {
        let paths = model.gitLogRepo.map(paths(of:))
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.gitLog.records.filter { record in
            switch kind {
            case .all: break
            case .actions: if record.isQuery { return false }
            case .problems: if !record.isProblem { return false }
            }
            if let paths, !paths.contains(record.directory ?? "") { return false }
            if !query.isEmpty {
                return record.commandLine.lowercased().contains(query)
                    || record.stderr.lowercased().contains(query)
                    || record.stdout.lowercased().contains(query)
                    || (record.failure?.lowercased().contains(query) ?? false)
            }
            return true
        }
    }

    /// The repo's folder and all of its worktrees.
    private func paths(of repoPath: String) -> Set<String> {
        var paths: Set<String> = [repoPath]
        for wt in model.repo(at: repoPath)?.snapshot?.worktrees ?? [] { paths.insert(wt.path) }
        return paths
    }

    /// Consecutive commands started within the same second, which is how a refresh shows up.
    private func batches(_ records: [GitRunRecord]) -> [RunBatch] {
        var batches: [RunBatch] = []
        for record in records {
            let second = Int(record.started.timeIntervalSinceReferenceDate)
            if let last = batches.last, last.second == second {
                batches[batches.count - 1].records.append(record)
            } else {
                batches.append(RunBatch(id: record.id, second: second, records: [record]))
            }
        }
        return batches
    }

    private func repoName(for record: GitRunRecord) -> String? {
        guard let dir = record.directory else { return nil }
        if let repo = model.repos.first(where: { $0.path == dir || $0.snapshot?.worktrees.contains { $0.path == dir } == true }) {
            return repo.name
        }
        return URL(fileURLWithPath: dir).lastPathComponent
    }
}

private struct RunBatch: Identifiable {
    let id: GitRunRecord.ID
    let second: Int
    var records: [GitRunRecord]
}

/// "19:56:02 · 14 commands · 4 repositories · 52 ms · all succeeded"
private struct BatchHeader: View {
    let batch: RunBatch
    let repositories: Int

    var body: some View {
        let records = batch.records
        let problems = records.count(where: \.isProblem)
        HStack(spacing: 6) {
            if let first = records.first {
                Text(first.started.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(summary)
            if problems > 0 {
                Text("· \(problems) problem\(problems == 1 ? "" : "s")").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var summary: String {
        let records = batch.records
        var parts = ["\(records.count) command\(records.count == 1 ? "" : "s")"]
        if repositories > 1 { parts.append("\(repositories) repositories") }
        if records.contains(where: \.isRunning) {
            parts.append("running")
        } else {
            parts.append(formatDuration(records.compactMap(\.duration).reduce(0, +)))
            if records.count > 1, records.allSatisfy(\.succeeded) { parts.append("all succeeded") }
        }
        return parts.joined(separator: " · ")
    }
}

/// One line per command: status, repository, the command, how long it took.
private struct RunRow: View {
    let record: GitRunRecord
    let repoName: String?

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(record: record)
                .frame(width: 14)
            Text(repoName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 100, alignment: .leading)
            command
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(record.commandLine)
            if let duration = record.duration {
                Text(formatDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    /// "git diff" stands out and the arguments recede; full commit hashes are cut to 7 characters.
    private var command: Text {
        let verb = record.arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        let head = ([record.tool] + (verb.map { [$0] } ?? [])).joined(separator: " ")
        let rest = record.arguments.dropFirst(verb == nil ? 0 : 1)
            .map { $0.replacing(/[0-9a-f]{40}/) { String($0.output.prefix(7)) } }
            .joined(separator: " ")
        return Text("\(Text(verbatim: head).fontWeight(.semibold)) \(Text(verbatim: rest).foregroundStyle(.secondary))")
    }
}

private struct StatusIcon: View {
    let record: GitRunRecord

    var body: some View {
        if record.isRunning {
            ProgressView().controlSize(.mini)
        } else if record.succeeded {
            // Success is the normal case, so it gets the quietest mark.
            Circle().fill(.green).frame(width: 6, height: 6)
        } else if !record.isProblem {
            // An optional lookup that came back empty, or a cancelled run: nothing to act on.
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                .help(record.failure == "Cancelled" ? "Cancelled" : "Failed, but Grove expects this lookup to fail sometimes and carries on without it")
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct RunDetail: View {
    let record: GitRunRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("$ ").foregroundStyle(.tertiary)
                        Text(verbatim: record.commandLine).textSelection(.enabled)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    Button { copyToPasteboard(report) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy command and output")
                }
                HStack(spacing: 8) {
                    tile("Exit code", record.exitCode.map { "\($0)" } ?? (record.isRunning ? "running" : "none"),
                         color: record.succeeded ? .green : record.isProblem ? .red : .primary)
                    tile("Took", record.duration.map(formatDuration) ?? "…")
                    tile("Started", record.started.formatted(date: .omitted, time: .standard))
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    if let dir = record.directory { row("Folder", dir.abbreviatingWithTilde) }
                    row("Date", record.started.formatted(date: .abbreviated, time: .omitted))
                    if let failure = record.failure { row("Problem", failure) }
                    if record.failureExpected && !record.succeeded && record.failure == nil {
                        row("Note", "Optional lookup: Grove carries on without it, e.g. a branch with no common history with the primary branch.")
                    }
                }
                .font(.callout)
                if record.stderr.isEmpty && record.stdout.isEmpty {
                    Text(record.isRunning ? "No output yet" : "No output on stdout or stderr")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    if !record.stderr.isEmpty { stream("Error output (stderr)", record.stderr) }
                    if !record.stdout.isEmpty { stream("Output (stdout)", record.stdout) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(color).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func stream(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Everything about the run as plain text, for pasting into an issue or chat.
    private var report: String {
        var lines = ["$ \(record.commandLine)"]
        if let dir = record.directory { lines.append("in \(dir)") }
        if let code = record.exitCode { lines.append("exit code \(code)") }
        if let failure = record.failure { lines.append(failure) }
        if !record.stderr.isEmpty { lines += ["--- stderr", record.stderr] }
        if !record.stdout.isEmpty { lines += ["--- stdout", record.stdout] }
        return lines.joined(separator: "\n")
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
}
