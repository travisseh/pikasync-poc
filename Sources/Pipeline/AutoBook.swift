import Foundation
import UserNotifications

/// Background book generation, restructured for the ~30s bg_refresh budget
/// (the wake iOS actually grants daily; bg_processing starved for 6 straight
/// days on an unused app). Each wake does a bounded slice:
///   - last month's book not made yet → score a ~15s chunk of last month;
///     once fully scored, the remainder (dedup/shortlist/3 sheets/server
///     judge) is cheap enough to attempt in one wake
///   - book already made → score a chunk of the CURRENT month so month-close
///     is nearly free when it arrives
/// Scores checkpoint after every photo, so an expired task loses nothing and
/// the next wake resumes. Success marker only set on a saved book.
@MainActor
enum AutoBook {
    static func tick(trigger: String) async {
        let cal = Calendar.current
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let marker = "autoBook-\(df.string(from: now))"
        guard let prevMonth = cal.date(byAdding: .month, value: -1, to: now) else { return }

        if UserDefaults.standard.bool(forKey: marker) {
            // Book done — pre-score the current month in the leftover budget.
            let r = await IncrementalScorer.scoreChunk(month: now, budget: 12)
            if r.newlyScored > 0 {
                WakeLog.record(trigger: "bg_score", newPhotos: r.newlyScored, totalPhotos: r.total,
                               note: "current month \(r.total - r.remaining)/\(r.total) scored")
            }
            return
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

        // Phase 2: scoring complete — the remainder is sheets + one server call.
        let label = DateFormatter.localizedString(from: prevMonth, dateStyle: .medium, timeStyle: .none)
        WakeLog.record(trigger: "bg_book", newPhotos: 0, totalPhotos: r.total,
                       note: "scores complete (\(trigger)) — building \(label) book")

        let runner = PipelineRunner()
        runner.trigger = "bg"
        let t0 = Date()
        await runner.run(month: prevMonth)  // scoring already done; goes straight to shortlist/sheets/judge

        if let err = runner.errorText {
            WakeLog.record(trigger: "bg_book", newPhotos: -1, totalPhotos: -1,
                           note: "failed after \(Int(Date().timeIntervalSince(t0)))s: \(err.prefix(120))")
            return  // marker stays unset so the next wake retries
        }

        UserDefaults.standard.set(true, forKey: marker)
        let picks = runner.book?.selections.count ?? 0
        WakeLog.record(trigger: "bg_book", newPhotos: picks, totalPhotos: 0,
                       note: "book ready in \(Int(Date().timeIntervalSince(t0)))s — \(runner.judgeInfo)")

        let content = UNMutableNotificationContent()
        content.title = "Your \(runner.book?.title ?? "monthly") book is ready"
        content.body = "Pikabook made your \(label) book in the background. Tap to see it."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "autobook-\(marker)", content: content, trigger: nil))
    }
}
