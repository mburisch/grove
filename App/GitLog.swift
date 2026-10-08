import Foundation
import GroveCore
import Observation

/// The most recent git runs, newest first, for the Git Output page. Kept in memory only.
@MainActor @Observable
final class GitLog {
    private(set) var records: [GitRunRecord] = []
    private let capacity = 500

    func record(_ run: GitRunRecord) {
        if let index = records.firstIndex(where: { $0.id == run.id }) {
            // Start and end are delivered separately and may arrive out of order; never let the
            // start overwrite the result.
            if run.isRunning && !records[index].isRunning { return }
            records[index] = run
        } else {
            records.insert(run, at: 0)
            if records.count > capacity { records.removeLast(records.count - capacity) }
        }
    }

    func clear() {
        records.removeAll { !$0.isRunning }
    }
}
