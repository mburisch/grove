import Foundation
import Testing
@testable import GroveCore

/// Open file descriptors of this process.
private func openDescriptors() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

@Test func finishedRunsReleaseTheirPipes() async throws {
    let git = GitRunner()
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    _ = try await git.run(["--version"], in: dir) // warm up
    try await Task.sleep(for: .milliseconds(200))
    let before = openDescriptors()
    for _ in 0..<100 {
        _ = try await git.run(["--version"], in: dir)
    }
    try await Task.sleep(for: .milliseconds(500))
    let after = openDescriptors()
    print("descriptors before \(before), after 100 runs \(after)")
    #expect(after - before < 10)
}
