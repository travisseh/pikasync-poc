import Foundation
import UIKit

struct BookSelection: Codable, Identifiable {
    let index: Int
    let page: Int
    let caption: String
    var id: Int { index }
}

struct BookResult: Codable {
    let title: String
    let cover_index: Int
    let selections: [BookSelection]
}

/// Calls the Anthropic Messages API directly with the contact sheets as images.
/// POC-only architecture — production would upload sheets to a server that
/// holds the key and runs the judge there.
enum JudgeClient {
    struct JudgeOutput {
        let book: BookResult
        let usageSummary: String
    }

    static func judge(sheets: [UIImage], monthLabel: String, count: Int, maxIndex: Int) async throws -> JudgeOutput {
        let prompt = """
        You are choosing photos for a printed monthly family photobook the parents will keep forever.

        The attached contact sheet images cover \(monthLabel). Each photo is labeled [index] with its date and face count. Valid indexes are 0 through \(maxIndex).

        Choose EXACTLY \(count) photos and design the book:
        - Chronological narrative arc across the month
        - Balance the people; include 3-5 non-people shots (places, food, details) as texture
        - Prefer emotional resonance and storytelling over technical perfection
        - Never pick two photos of the same scene/moment

        Respond with ONLY a JSON object, no other text:
        {"title": "short book title", "cover_index": <index>, "selections": [{"index": <int>, "page": <1-\(count) in book order>, "caption": "<=8 words, factual"}]}
        The selections array must contain exactly \(count) entries with distinct indexes.
        """

        var content: [[String: Any]] = []
        for sheet in sheets {
            guard let jpeg = sheet.jpegData(compressionQuality: 0.7) else { continue }
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
            ])
        }
        content.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 4000,
            "messages": [["role": "user", "content": content]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(Secrets.anthropicKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.message("API \( (resp as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(300))")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inTok = usage["input_tokens"] as? Int ?? 0
        let outTok = usage["output_tokens"] as? Int ?? 0
        let cost = Double(inTok) * 3.0 / 1e6 + Double(outTok) * 15.0 / 1e6
        let usageSummary = String(format: "%d in / %d out tokens ≈ $%.3f (sonnet)", inTok, outTok, cost)

        guard let blocks = json["content"] as? [[String: Any]],
              let text = blocks.compactMap({ $0["text"] as? String }).first else {
            throw PipelineError.message("no text in response")
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw PipelineError.message("no JSON in judge output: \(text.prefix(200))")
        }
        let jsonStr = String(text[start...end])
        let book = try JSONDecoder().decode(BookResult.self, from: Data(jsonStr.utf8))

        // validation, mirroring judge.py
        let idxs = book.selections.map(\.index)
        if Set(idxs).count != idxs.count { throw PipelineError.message("judge returned duplicate indexes") }
        if idxs.contains(where: { $0 < 0 || $0 > maxIndex }) { throw PipelineError.message("judge returned out-of-range index") }

        return JudgeOutput(book: book, usageSummary: usageSummary)
    }
}
