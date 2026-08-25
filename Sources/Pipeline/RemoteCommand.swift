import Foundation

/// Remote control for the POC: drop Documents/command.json onto the device
/// (devicectl copy) with {"action": "run", "month": "yyyy-MM"}, then launch the
/// app (devicectl process launch). On becoming active the app consumes the file
/// and runs the pipeline headlessly; results land in runs.json / last-run.json.
@MainActor
enum RemoteCommand {
    struct Command: Codable {
        let action: String
        let month: String?
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("command.json")
    }

    private static var executing = false

    static func checkAndRun() {
        guard !executing,
              let data = try? Data(contentsOf: url),
              let cmd = try? JSONDecoder().decode(Command.self, from: data) else { return }
        try? FileManager.default.removeItem(at: url)  // consume before executing: never double-run

        guard let monthStr = cmd.month else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        guard let month = df.date(from: monthStr) else {
            RunStatusLog.write(month: monthStr, status: "failed", error: "bad month in command.json",
                               stages: [], trigger: "remote")
            return
        }

        executing = true
        WakeLog.record(trigger: "remote_cmd", newPhotos: 0, totalPhotos: 0, note: "\(cmd.action) for \(monthStr)")
        Task { @MainActor in
            defer { executing = false }
            switch cmd.action {
            case "run":
                let runner = PipelineRunner()
                runner.trigger = "remote"
                await runner.run(month: month)
                WakeLog.record(trigger: "remote_cmd", newPhotos: runner.book?.selections.count ?? -1,
                               totalPhotos: 0, note: runner.errorText.map { "failed: \($0.prefix(120))" } ?? "book ready")
            case "score":
                // Fill the incremental score store only (no judge) so a later
                // bg_refresh wake can finish the book within its ~30s budget.
                let r = await IncrementalScorer.scoreChunk(month: month, budget: nil)
                RunStatusLog.write(month: monthStr, status: r.complete ? "scored" : "score incomplete",
                                   error: nil, stages: ["\(r.total) in month, \(r.newlyScored) newly scored"],
                                   trigger: "remote-score")
                WakeLog.record(trigger: "remote_cmd", newPhotos: r.newlyScored, totalPhotos: r.total,
                               note: "scored \(monthStr): \(r.total - r.remaining)/\(r.total)")
            default:
                RunStatusLog.write(month: monthStr, status: "failed", error: "unknown action \(cmd.action)",
                                   stages: [], trigger: "remote")
            }
        }
    }
}
