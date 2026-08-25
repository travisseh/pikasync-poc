import Foundation

/// Resumable month-close state for background book generation. Persisted to
/// Documents/autobook-state.json so each ~30s bg_refresh wake can do one step
/// and exit: "submitted" (job in flight on the server) is the only phase that
/// spans wakes; everything else is derived from the score store + marker.
struct AutoBookState: Codable {
    var monthKey: String            // "yyyy-MM" of the month being built
    var jobId: String
    var shortlistIDs: [String]      // shortlist order == judge index space
    var bookCount: Int
    var monthName: String
    var submittedAt: Date
    var correctionRound: Int        // 0 = first job, 1 = corrected re-pick

    static let staleAfter: TimeInterval = 20 * 60  // job with no result → resubmit

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("autobook-state.json")
    }

    static func load() -> AutoBookState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AutoBookState.self, from: data)
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
