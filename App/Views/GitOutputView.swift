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
                    Text("Problems").tag(Kind.problems)
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
                List(records, selection: $selection) { record in
                    RunRow(record: record, repoName: repoName(for: record))
                        .tag(record.id)
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
            case .latestProblem: selection = (finished.first { !$0.succeeded } ?? finished.first)?.id
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
            case .problems: if record.isRunning || record.succeeded { return false }
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

    private func repoName(for record: GitRunRecord) -> String? {
        guard let dir = record.directory else { return nil }
        if let repo = model.repos.first(where: { $0.path == dir || $0.snapshot?.worktrees.contains { $0.path == dir } == true }) {
            return repo.name
        }
        return URL(fileURLWithPath: dir).lastPathComponent
    }
}

private struct RunRow: View {
    let record: GitRunRecord
    let repoName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusIcon(record: record)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.commandLine)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    if let repoName { Text(repoName) }
                    Text(record.started.formatted(date: .omitted, time: .standard))
                    if let duration = record.duration { Text(formatDuration(duration)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct StatusIcon: View {
    let record: GitRunRecord

    var body: some View {
        if record.isRunning {
            ProgressView().controlSize(.mini)
        } else if record.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct RunDetail: View {
    let record: GitRunRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    StatusIcon(record: record)
                    Text(record.commandLine)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button { copyToPasteboard(report) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy command and output")
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    if let dir = record.directory { row("Folder", dir.abbreviatingWithTilde) }
                    row("Started", record.started.formatted(date: .abbreviated, time: .standard))
                    if let duration = record.duration { row("Took", formatDuration(duration)) }
                    if let code = record.exitCode { row("Exit code", "\(code)") }
                    if let failure = record.failure { row("Problem", failure) }
                }
                .font(.callout)
                stream("Error output (stderr)", record.stderr)
                stream("Output (stdout)", record.stdout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func stream(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
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
