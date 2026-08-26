import Foundation
import UserNotifications

/// Background book generation as a resumable state machine sized for the
/// ~30s bg_refresh budget (the wake iOS grants daily). Each wake does ONE
/// bounded step and exits:
///   1. score a ~15s chunk of last month (checkpointed per photo)
///   2. scoring complete + no job → shortlist, sheets, SUBMIT async judge
///      (~2s), persist {jobId, shortlist} and exit
///   3. job submitted → poll result: pending → exit; failed/stale → drop the
///      job (next wake resubmits); done → scene check on the picks, either
///      submit ONE corrected job or save the book + notify + set the marker
///   4. marker set → pre-score the current month so month-close is cheap
/// bg_processing (minutes) and remote ticks run steps 2→3 in one go by
/// waiting on the job. The success marker is only set once a book is saved.
@MainActor
enum AutoBook {
    private static let pollWindow: TimeInterval = 150  // processing/remote wakes only

    static func tick(trigger: String) async {
        let cal = Calendar.current
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let marker = "autoBook-\(df.string(from: now))"
        guard let prevMonth = cal.date(byAdding: .month, value: -1, to: now) else { return }
        let prevKey = df.string(from: prevMonth)
        let generous = trigger == "bg_processing" || trigger == "remote"
        // Experiment flag (set via remote command): prove the bg_refresh-only
        // path by refusing to let processing wakes build the book.
        if trigger == "bg_processing" && UserDefaults.standard.bool(forKey: "experiment.skipProcessing") {
            WakeLog.record(trigger: "bg_book", newPhotos: 0, totalPhotos: 0, note: "processing wake skipped (refresh-only experiment)")
            return
        }

        if UserDefaults.standard.bool(forKey: marker) {
            // Book done — pre-score the current month in the leftover budget,
            // and let a generous wake catch up any auto-share that was skipped.
            if generous { await ShareClient.sweepUnshared() }
            let r = await IncrementalScorer.scoreChunk(month: now, budget: 12)
            if r.newlyScored > 0 {
                WakeLog.record(trigger: "bg_score", newPhotos: r.newlyScored, totalPhotos: r.total,
                               note: "current month \(r.total - r.remaining)/\(r.total) scored")
            }
            return
        }

        // A job already in flight for this month? Collect (or drop it).
        if let state = AutoBookState.load(), state.monthKey == prevKey {
            await collect(state: state, month: prevMonth, marker: marker, trigger: trigger, generous: generous)
            return
        } else if AutoBookState.load() != nil {
            AutoBookState.clear()  // stale state from another month
        }

        // Phase 1: drain last month's scoring in bounded chunks.
        let r = await IncrementalScorer.scoreChunk(month: prevMonth, budget: 15)
        guard r.total >= 0 else {
            WakeLog.record(trigger: "bg_score", newPhotos: -1, totalPhotos: -1, note: "no photo permission")
            return
        }
        if r.total < 8 {
            UserDefaults.standard.set(true, forKey: marker)  // month too small; skip
            WakeLog.record(trigger: "bg_book", newPhotos: 0, totalPhotos: r.total, note: "month too small, skipped")
            return
        }
        if !r.complete {
            WakeLog.record(trigger: "bg_score", newPhotos: r.newlyScored, totalPhotos: r.total,
                           note: "last month \(r.total - r.remaining)/\(r.total) scored, resuming next wake")
            return
        }

        // Phase 2: shortlist + sheets + async submit (a few seconds).
        let runner = PipelineRunner()
        runner.trigger = "bg"
        let t0 = Date()
        do {
            let prepared = try await runner.prepare(month: prevMonth, scores: IncrementalScorer.loadScores(month: prevMonth))
            let jobId = try await JudgeClient.submit(sheets: prepared.sheets, monthLabel: prepared.monthName,
                                                     count: prepared.bookCount, maxIndex: prepared.chosen.count - 1)
            let state = AutoBookState(monthKey: prevKey, jobId: jobId, shortlistIDs: prepared.chosen.map(\.id),
                                      bookCount: prepared.bookCount, monthName: prepared.monthName,
                                      submittedAt: Date(), correctionRound: 0)
            state.save()
            WakeLog.record(trigger: "bg_book", newPhotos: prepared.chosen.count, totalPhotos: r.total,
                           note: "submitted job \(jobId.prefix(8)) (\(trigger)) — \(prepared.sheets.count) sheets, \(prepared.bookCount)-page \(prepared.monthName) book, \(Int(Date().timeIntervalSince(t0)))s")
            RunStatusLog.write(month: prevKey, status: "submitted", error: nil,
                               stages: runner.stageTimes.map { "\($0.name): \($0.detail)" }, trigger: trigger)
            if generous {
                await collect(state: state, month: prevMonth, marker: marker, trigger: trigger, generous: true)
            }
        } catch {
            WakeLog.record(trigger: "bg_book", newPhotos: -1, totalPhotos: -1,
                           note: "submit failed (\(trigger)): \(String(describing: error).prefix(120))")
            RunStatusLog.write(month: prevKey, status: "submit failed", error: "\(error)",
                               stages: runner.stageTimes.map { "\($0.name): \($0.detail)" }, trigger: trigger)
        }
    }

    /// Poll the async judge; on a result, either re-submit once with a scene
    /// correction or save the book. Generous wakes wait up to `pollWindow`.
    private static func collect(state: AutoBookState, month: Date, marker: String, trigger: String, generous: Bool) async {
        var state = state
        let chosen = PipelineRunner.chosen(fromIDs: state.shortlistIDs, month: month)
        let deadline = Date().addingTimeInterval(generous ? pollWindow : 0)
        while true {
            let status: JudgeClient.JobStatus
            do {
                status = try await JudgeClient.result(jobId: state.jobId, maxIndex: chosen.count - 1)
            } catch {
                WakeLog.record(trigger: "bg_book", newPhotos: -1, totalPhotos: -1,
                               note: "poll error job \(state.jobId.prefix(8)): \(String(describing: error).prefix(100))")
                return  // transient; keep the job, try next wake
            }
            switch status {
            case .pending:
                if Date().timeIntervalSince(state.submittedAt) > AutoBookState.staleAfter {
                    AutoBookState.clear()
                    WakeLog.record(trigger: "bg_book", newPhotos: 0, totalPhotos: 0,
                                   note: "job \(state.jobId.prefix(8)) stale (\(Int(Date().timeIntervalSince(state.submittedAt) / 60))m pending) — dropped, resubmitting next wake")
                    return
                }
                if Date() < deadline {
                    try? await Task.sleep(for: .seconds(6))
                    continue
                }
                WakeLog.record(trigger: "bg_book", newPhotos: 0, totalPhotos: 0,
                               note: "job \(state.jobId.prefix(8)) still pending (\(trigger)) — collecting next wake")
                return
            case .failed(let err):
                AutoBookState.clear()
                WakeLog.record(trigger: "bg_book", newPhotos: -1, totalPhotos: -1,
                               note: "job \(state.jobId.prefix(8)) failed: \(err.prefix(100)) — resubmitting next wake")
                return
            case .done(let result):
                let runner = PipelineRunner()
                runner.trigger = "bg"
                let violations = runner.sceneViolations(result.book, chosen: chosen)
                if violations.count >= 2 && state.correctionRound == 0 {
                    // One corrective round: re-render sheets from the persisted
                    // shortlist and submit again with the scene correction.
                    do {
                        let thumbs = await runner.loadThumbs(ids: chosen.map(\.id), size: CGSize(width: 420, height: 420))
                        let sheets = ContactSheetRenderer.render(scores: chosen, thumbs: thumbs)
                        let jobId = try await JudgeClient.submit(sheets: sheets, monthLabel: state.monthName, count: state.bookCount,
                                                                 maxIndex: chosen.count - 1, correction: runner.correctionText(violations))
                        state.jobId = jobId
                        state.submittedAt = Date()
                        state.correctionRound = 1
                        state.save()
                        WakeLog.record(trigger: "bg_book", newPhotos: violations.count, totalPhotos: 0,
                                       note: "collected job — \(violations.count) same-scene pairs, corrected job \(jobId.prefix(8)) submitted")
                        if generous { continue }  // keep waiting on the corrected job
                    } catch {
                        // Accept the first answer rather than loop forever.
                        WakeLog.record(trigger: "bg_book", newPhotos: -1, totalPhotos: -1,
                                       note: "correction submit failed, accepting first pick: \(String(describing: error).prefix(80))")
                        await finish(result: result, chosen: chosen, state: state, runner: runner, marker: marker, trigger: trigger, generous: generous)
                    }
                    return
                }
                let note = violations.count == 1 ? " (1 residual pair tolerated)" : (violations.count >= 2 ? " (\(violations.count) pairs still similar after correction, accepted)" : "")
                runner.stageTimes.append(.init(name: "async judge", seconds: Date().timeIntervalSince(state.submittedAt),
                                               detail: "job \(state.jobId.prefix(8)) round \(state.correctionRound)\(note)"))
                await finish(result: result, chosen: chosen, state: state, runner: runner, marker: marker, trigger: trigger, generous: generous)
                return
            }
        }
    }

    private static func finish(result: JudgeClient.JudgeOutput, chosen: [PhotoScore], state: AutoBookState,
                               runner: PipelineRunner, marker: String, trigger: String, generous: Bool) async {
        // Share inline only on generous wakes (uploading ~18 photos doesn't fit
        // a refresh window); otherwise the app-open sweep / next generous wake.
        guard let saved = await runner.saveBook(result: result, chosen: chosen, monthName: state.monthName, share: generous) else {
            AutoBookState.clear()
            WakeLog.record(trigger: "bg_book", newPhotos: -1, totalPhotos: -1, note: "collected job but cover index unmapped — resubmitting next wake")
            return
        }
        UserDefaults.standard.set(true, forKey: marker)
        AutoBookState.clear()
        WakeLog.record(trigger: "bg_book", newPhotos: saved.selections.count, totalPhotos: 0,
                       note: "collected job \(state.jobId.prefix(8)) (\(trigger)) — book ready — \(result.usageSummary)")
        RunStatusLog.write(month: state.monthKey, status: "done — \(saved.selections.count)-photo book ready", error: nil,
                           stages: runner.stageTimes.map { "\($0.name): \($0.detail)" }, trigger: "bg-\(trigger)")

        let content = UNMutableNotificationContent()
        content.title = "Your \(saved.title) book is ready"
        content.body = "Pikabook made your \(state.monthName) book in the background. Tap to see it."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "autobook-\(marker)", content: content, trigger: nil))
    }
}
