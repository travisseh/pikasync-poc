import Foundation

/// Persists the outcome of every pipeline run (manual, remote, or background)
/// to Documents/last-run.json so failures can be pulled off the device with
/// devicectl instead of screenshotted.
enum RunStatusLog {
    struct Entry: Codable {
        let finishedAt: Date
        let month: String
        let status: String
        let error: String?
        let stages: [String]
        let trigger: String
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-run.json")
    }

    static func write(month: String, status: String, error: String?, stages: [String], trigger: String) {
        var history = load()
        history.insert(Entry(finishedAt: Date(), month: month, status: status,
                             error: error, stages: stages, trigger: trigger), at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(history).write(to: url, options: .atomic)
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Entry].self, from: data)) ?? []
    }
}
