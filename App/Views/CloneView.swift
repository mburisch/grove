import AppKit
import GitItCore
import SwiftUI

struct CloneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var job = model.clone
        let source = job.source

        Form {
            Section {
                TextField("Repository", text: $job.input, prompt: Text("https://github.com/owner/repo or owner/repo"))
                    .onSubmit(startIfReady)
                if let gh = source?.gitHub {
                    LabeledContent("GitHub", value: gh.slug)
                } else if source != nil {
                    LabeledContent("URL", value: source?.url ?? "")
                } else if !job.input.isEmpty {
                    Text("Not a recognized git URL").foregroundStyle(.red).font(.caption)
                }
            }

            Section("Destination") {
                HStack {
                    TextField("Folder", text: $job.destinationRoot)
                    Button("Choose…") {
                        if let url = Panels.chooseFolders(startingAt: job.destinationRoot).first {
                            job.destinationRoot = url.path.abbreviatingWithTilde
                        }
                    }
                }
                TextField("Name", text: $job.folderName, prompt: Text(source?.suggestedName ?? "repo"))
                LabeledContent("Clones into", value: job.destination.path.abbreviatingWithTilde)
                if source != nil && job.destinationExists {
                    Text("That folder already exists").foregroundStyle(.red).font(.caption)
                }
            }

            Section("Checkout") {
                Picker("Mode", selection: $job.mode) {
                    Text("Full").tag(CheckoutMode.full)
                    Text("Shallow (primary branch)").tag(CheckoutMode.shallow)
                    Text("Blobless").tag(CheckoutMode.blobless)
                }
                .pickerStyle(.radioGroup)
                if job.mode == .shallow {
                    Stepper("Depth: \(job.depth)", value: $job.depth, in: 1...1000)
                }
                Text(explanation(job.mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let error = job.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if job.isRunning {
                    VStack(alignment: .leading) {
                        ProgressView(value: job.progress?.fraction ?? 0)
                        Text(job.progress?.phase ?? "Starting…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    if job.isRunning {
                        Button("Cancel") { job.task?.cancel() }
                    } else {
                        Button("Clone", action: startIfReady)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canStart)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: prefill)
    }

    private var canStart: Bool {
        let job = model.clone
        return job.source != nil && !job.destinationExists && !job.destinationRoot.isEmpty && !job.isRunning
    }

    private func startIfReady() {
        if canStart { model.startClone() }
    }

    private func prefill() {
        let job = model.clone
        if job.destinationRoot.isEmpty { job.destinationRoot = model.config.cloneRoot }
        guard job.input.isEmpty, !job.isRunning,
              let text = NSPasteboard.general.string(forType: .string),
              CloneSource(input: text)?.gitHub != nil else { return }
        job.input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func explanation(_ mode: CheckoutMode) -> String {
        switch mode {
        case .full:
            "Complete history and all file contents."
        case .shallow:
            "Only the primary branch with truncated history. Fetches add new commits on top; use “Trim History” to cut it back."
        case .blobless:
            "All commits and branches, but file contents are downloaded only when checked out. Fetches keep the filter."
        }
    }
}
