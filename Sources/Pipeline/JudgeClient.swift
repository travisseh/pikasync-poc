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

    static let submitURL = URL(string: "https://pikasync-judge.vercel.app/api/judge/submit")!
    static let resultURL = URL(string: "https://pikasync-judge.vercel.app/api/judge/result")!

    enum JobStatus {
        case pending
        case done(JudgeOutput)
        case failed(String)
    }

    private static func requestBody(sheets: [UIImage], monthLabel: String, count: Int, maxIndex: Int, correction: String?) throws -> Data {
        var body: [String: Any] = [
            "monthLabel": monthLabel,
            "count": count,
            "maxIndex": maxIndex,
            "sheets": encodeSheets(sheets),
        ]
        if let correction { body["correction"] = correction }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Async path for background wakes: returns a jobId in ~1-2s; the server
    /// judges after responding. Collect with `result(jobId:)` on a later wake.
    static func submit(sheets: [UIImage], monthLabel: String, count: Int, maxIndex: Int, correction: String? = nil) async throws -> String {
        var req = URLRequest(url: submitURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 25
        req.httpBody = try requestBody(sheets: sheets, monthLabel: monthLabel, count: count, maxIndex: maxIndex, correction: correction)
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 202 || http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.message("judge submit \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(200))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = obj["jobId"] as? String else {
            throw PipelineError.message("judge submit: no jobId in response")
        }
        Analytics.capture("judge_submitted", ["job_id": jobId, "sheets": sheets.count, "count": count])
        return jobId
    }

    static func result(jobId: String, maxIndex: Int) async throws -> JobStatus {
        var comps = URLComponents(url: resultURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "jobId", value: jobId)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.message("judge result \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(200))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else {
            throw PipelineError.message("judge result: malformed response")
        }
        switch status {
        case "pending": return .pending
        case "failed": return .failed((obj["error"] as? String) ?? "unknown server failure")
        case "done":
            let parsed = try JSONDecoder().decode(ServerResponse.self, from: data)
            return .done(try validate(parsed, maxIndex: maxIndex))
        default: throw PipelineError.message("judge result: unknown status \(status)")
        }
    }

    private static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        // iPhones intermittently drop uploads with -1005 "connection lost"
        // (stale connection reuse); a fresh session + retry almost always succeeds.
        var lastError: Error = PipelineError.message("judge request never attempted")
        for attempt in 1...3 {
            do {
                let session = URLSession(configuration: .ephemeral)
                return try await session.data(for: req)
            } catch let e as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(e.code) {
                lastError = e
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        throw lastError
    }

    private static func validate(_ parsed: ServerResponse, maxIndex: Int) throws -> JudgeOutput {
        // Server validates too; re-check here so a bad deploy can't corrupt runs.
        let idxs = parsed.book.selections.map(\.index)
        if Set(idxs).count != idxs.count { throw PipelineError.message("judge returned duplicate indexes") }
        if idxs.contains(where: { $0 < 0 || $0 > maxIndex }) { throw PipelineError.message("judge returned out-of-range index") }
        let inTok = parsed.usage?.input_tokens ?? 0
        let outTok = parsed.usage?.output_tokens ?? 0
        let cost = Double(inTok) * 3.0 / 1e6 + Double(outTok) * 15.0 / 1e6
        let usageSummary = String(format: "%d in / %d out tokens ≈ $%.3f (sonnet, server)", inTok, outTok, cost)
        Analytics.capture("judge_collected", ["input_tokens": inTok, "output_tokens": outTok, "cost_usd": cost])
        return JudgeOutput(book: parsed.book, usageSummary: usageSummary)
    }

    static func judge(sheets: [UIImage], monthLabel: String, count: Int, maxIndex: Int, correction: String? = nil) async throws -> JudgeOutput {
        var req = URLRequest(url: serverURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 300
        req.httpBody = try requestBody(sheets: sheets, monthLabel: monthLabel, count: count, maxIndex: maxIndex, correction: correction)

        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.message("judge server \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(300))")
        }
        let parsed = try JSONDecoder().decode(ServerResponse.self, from: data)
        return try validate(parsed, maxIndex: maxIndex)
    }
}
