import Foundation
import UIKit

/// Uploads a saved book to the pikabook-share Convex backend and returns the
/// public share link. Flow: create-book -> PUT each page JPEG to its storage
/// upload URL -> finalize-book. The shareId doubles as the feedback token.
enum ShareClient {
    static let convexSite = URL(string: "https://silent-marmot-268.convex.site")!
    static let shareBase = "https://pikabook-share.vercel.app/b/"

    struct ShareResult {
        let url: String
        let shareID: String
    }

    static func upload(run: SavedRun, progress: @MainActor @escaping (String) -> Void) async throws -> ShareResult {
        // Page 0 is the cover; book pages follow in order.
        let ordered = [run.coverAssetID] + run.selections.sorted { $0.page < $1.page }.map(\.assetID)
        await progress("loading photos…")
        let images = await AssetLoader.load(ids: Array(Set(ordered)), size: CGSize(width: 1600, height: 1600))

        struct CreateResp: Codable {
            let bookId: String
            let shareId: String
            let uploadUrls: [String]
        }
        await progress("creating book…")
        let create: CreateResp = try await postJSON(path: "/create-book", body: [
            "title": run.title,
            "monthLabel": run.monthLabel,
            "deviceName": UIDevice.current.name,
            "pageCount": ordered.count,
        ])

        struct UploadResp: Codable { let storageId: String }
        var pages: [[String: Any]] = []
        for (i, assetID) in ordered.enumerated() {
            guard let img = images[assetID], let jpeg = img.jpegData(compressionQuality: 0.8) else {
                throw PipelineError.message("couldn't load photo for page \(i)")
            }
            await progress("uploading \(i + 1)/\(ordered.count)…")
            var req = URLRequest(url: URL(string: create.uploadUrls[i])!)
            req.httpMethod = "POST"
            req.setValue("image/jpeg", forHTTPHeaderField: "content-type")
            req.httpBody = jpeg
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw PipelineError.message("page upload failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1))")
            }
            let up = try JSONDecoder().decode(UploadResp.self, from: data)
            pages.append(["page": i, "storageId": up.storageId])
        }

        await progress("finalizing…")
        struct OkResp: Codable { let ok: Bool }
        let _: OkResp = try await postJSON(path: "/finalize-book", body: [
            "bookId": create.bookId,
            "pages": pages,
        ])
        return ShareResult(url: shareBase + create.shareId, shareID: create.shareId)
    }

    /// In-app feedback lands in the same Convex table the web viewers write to.
    static func sendFeedback(shareID: String, page: Int?, reaction: String?, text: String?) async throws {
        var body: [String: Any] = ["shareId": shareID, "author": "Travisse (in-app)"]
        if let page { body["page"] = page }
        if let reaction { body["reaction"] = reaction }
        if let text, !text.isEmpty { body["text"] = text }
        struct OkResp: Codable { let ok: Bool }
        let _: OkResp = try await postJSON(path: "/feedback", body: body)
    }

    private static func postJSON<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: convexSite.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.message("share server \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(text.prefix(200))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
