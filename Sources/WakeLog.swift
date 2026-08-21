import Foundation

/// One row per wake event. Persisted locally AND posted to ntfy.sh so wakes are
/// visible on any device without running a server.
struct WakeEvent: Codable, Identifiable {
    var id = UUID()
    let timestamp: Date
    let trigger: String      // foreground | bg_refresh | bg_processing | shortcut | push
    let newPhotos: Int
    let totalPhotos: Int
    let note: String
}

enum WakeLog {
    /// Main app and the standalone background-test app log to separate topics
    /// so the 7-day experiment stays clean while the main app gets iterated on.
    static let ntfyTopic = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".bg")
        ? "pikasync-bg-trav-8347"       // subscribe: https://ntfy.sh/pikasync-bg-trav-8347
        : "pikasync-poc-trav-8347"      // subscribe: https://ntfy.sh/pikasync-poc-trav-8347

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wake-log.json")
    }

    static func load() -> [WakeEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([WakeEvent].self, from: data) else { return [] }
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    static func record(trigger: String, newPhotos: Int, totalPhotos: Int, note: String = "") {
        var events = load()
        let event = WakeEvent(timestamp: Date(), trigger: trigger,
                              newPhotos: newPhotos, totalPhotos: totalPhotos, note: note)
        events.insert(event, at: 0)
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: fileURL)
        }
        post(event)
    }

    /// Fire-and-forget wake beacon. ntfy.sh needs no account; the topic IS the auth.
    private static func post(_ e: WakeEvent) {
        guard let url = URL(string: "https://ntfy.sh/\(ntfyTopic)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm:ss"
        req.httpBody = "[\(e.trigger)] \(fmt.string(from: e.timestamp)) new=\(e.newPhotos) total=\(e.totalPhotos) \(e.note)"
            .data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
}
