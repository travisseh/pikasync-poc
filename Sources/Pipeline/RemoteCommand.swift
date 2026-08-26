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
        let flag: String?
        let value: Bool?
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

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let monthStr = cmd.month ?? ""
        let month = df.date(from: monthStr)
        if cmd.action != "bgtick" && month == nil {
            RunStatusLog.write(month: monthStr, status: "failed", error: "bad month in command.json",
                               stages: [], trigger: "remote")
            return
        }

        executing = true
        WakeLog.record(trigger: "remote_cmd", newPhotos: 0, totalPhotos: 0, note: "\(cmd.action) \(monthStr)")
        Task { @MainActor in
            defer { executing = false }
            switch cmd.action {
            case "resetMonth":
                // Re-arm background generation: the marker is keyed by the month
                // the wake runs in (e.g. 2026-08 builds July), so pass that key.
                let marker = "autoBook-\(monthStr)"
                let was = UserDefaults.standard.bool(forKey: marker)
                UserDefaults.standard.removeObject(forKey: marker)
                AutoBookState.clear()
                RunStatusLog.write(month: monthStr, status: "reset", error: nil,
                                   stages: ["marker \(marker) was \(was ? "set" : "unset"), now cleared; autobook-state cleared"],
                                   trigger: "remote-reset")
                WakeLog.record(trigger: "remote_cmd", newPhotos: 0, totalPhotos: 0, note: "reset \(marker) (was \(was))")
            case "setFlag":
                // {"action":"setFlag","month":"<any>","flag":"experiment.skipProcessing","value":true}
                if let flag = cmd.flag {
                    UserDefaults.standard.set(cmd.value ?? true, forKey: flag)
                    RunStatusLog.write(month: monthStr, status: "flag set", error: nil,
                                       stages: ["\(flag) = \(cmd.value ?? true)"], trigger: "remote-flag")
                    WakeLog.record(trigger: "remote_cmd", newPhotos: 0, totalPhotos: 0, note: "flag \(flag)=\(cmd.value ?? true)")
                }
            case "bgtick":
                await AutoBook.tick(trigger: "remote")
                RunStatusLog.write(month: monthStr, status: "bgtick complete", error: nil, stages: [], trigger: "remote-bgtick")
            case "run":
                let runner = PipelineRunner()
                runner.trigger = "remote"
                await runner.run(month: month!)
                WakeLog.record(trigger: "remote_cmd", newPhotos: runner.book?.selections.count ?? -1,
                               totalPhotos: 0, note: runner.errorText.map { "failed: \($0.prefix(120))" } ?? "book ready")
            case "score":
                // Fill the incremental score store only (no judge) so a later
                // bg_refresh wake can finish the book within its ~30s budget.
                let r = await IncrementalScorer.scoreChunk(month: month!, budget: nil)
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
