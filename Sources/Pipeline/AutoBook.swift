import Foundation
import UserNotifications

/// Background book generation: on a bg_processing wake, generate LAST month's
/// book — once per calendar month — and notify. Every step beacons to the wake
/// log so the experiment is observable without opening the app.
@MainActor
enum AutoBook {
    static func generateIfDue() async {
        let cal = Calendar.current
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let marker = "autoBook-\(df.string(from: now))"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        guard let prevMonth = cal.date(byAdding: .month, value: -1, to: now) else { return }

        let label = DateFormatter.localizedString(from: prevMonth, dateStyle: .medium, timeStyle: .none)
        WakeLog.record(trigger: "bg_book", newPhotos: 0, totalPhotos: 0, note: "generating book for \(label)")

        let runner = PipelineRunner()
        let t0 = Date()
        await runner.run(month: prevMonth)

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
