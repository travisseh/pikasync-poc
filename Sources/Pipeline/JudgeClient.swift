import Foundation
import UIKit

struct BookSelection: Codable, Identifiable {
    let index: Int
    let page: Int
    var id: Int { index }
}

struct BookResult: Codable {
    let title: String
    let cover_index: Int
    let selections: [BookSelection]
}

/// Thin client for the server-side judge (Vercel). The phone uploads only the
/// contact sheets; the Anthropic key and prompt live on the server, and the
/// judge output carries no captions — pages are photo + order only.
enum JudgeClient {
    static let serverURL = URL(string: "https://pikasync-judge.vercel.app/api/judge")!

    struct JudgeOutput {
        let book: BookResult
        let usageSummary: String
    }

    private struct ServerResponse: Codable {
        struct Usage: Codable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        let book: BookResult
        let usage: Usage?
    }

    /// Vercel rejects request bodies over 4.5MB; step quality down until the
    /// base64 payload fits with headroom.
    private static func encodeSheets(_ sheets: [UIImage]) -> [String] {
        for quality in [0.7, 0.5, 0.35] {
            let encoded = sheets.compactMap { $0.jpegData(compressionQuality: quality)?.base64EncodedString() }
            let total = encoded.reduce(0) { $0 + $1.utf8.count }
            if total < 3_800_000 { return encoded }
        }
        return sheets.compactMap { $0.jpegData(compressionQuality: 0.25)?.base64EncodedString() }
    }

    static func judge(sheets: [UIImage], monthLabel: String, count: Int, maxIndex: Int, correction: String? = nil) async throws -> JudgeOutput {
        var body: [String: Any] = [
            "monthLabel": monthLabel,
            "count": count,
            "maxIndex": maxIndex,
            "sheets": encodeSheets(sheets),
        ]
        if let correction { body["correction"] = correction }

        var req = URLRequest(url: serverURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // iPhones intermittently drop large uploads with -1005 "connection lost"
        // (stale connection reuse); a fresh session + retry almost always succeeds.
        var lastError: Error = PipelineError.message("judge request never attempted")
        var result: (Data, URLResponse)? = nil
        for attempt in 1...3 {
            do {
                let session = URLSession(configuration: .ephemeral)
                result = try await session.data(for: req)
                break
            } catch let e as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(e.code) {
                lastError = e
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        guard let (data, resp) = result else { throw lastError }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.message("judge server \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(300))")
        }

        let parsed = try JSONDecoder().decode(ServerResponse.self, from: data)

        // Server validates too; re-check here so a bad deploy can't corrupt runs.
        let idxs = parsed.book.selections.map(\.index)
        if Set(idxs).count != idxs.count { throw PipelineError.message("judge returned duplicate indexes") }
        if idxs.contains(where: { $0 < 0 || $0 > maxIndex }) { throw PipelineError.message("judge returned out-of-range index") }

        let inTok = parsed.usage?.input_tokens ?? 0
        let outTok = parsed.usage?.output_tokens ?? 0
        let cost = Double(inTok) * 3.0 / 1e6 + Double(outTok) * 15.0 / 1e6
        let usageSummary = String(format: "%d in / %d out tokens ≈ $%.3f (sonnet, server)", inTok, outTok, cost)
        return JudgeOutput(book: parsed.book, usageSummary: usageSummary)
    }
}
