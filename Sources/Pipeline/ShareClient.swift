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

    /// Idempotent share: returns the cached link, or uploads once and persists
    /// it on the run. Safe to call from anywhere (UI, pipeline, background).
    @MainActor
    static func ensureShared(runID: UUID, progress: @MainActor @escaping (String) -> Void = { _ in }) async -> ShareResult? {
        guard let run = RunStore.shared.runs.first(where: { $0.id == runID }) else { return nil }
        if let url = run.shareURL, let id = run.shareID {
            return ShareResult(url: url, shareID: id)
        }
        do {
            let result = try await upload(run: run, progress: progress)
            RunStore.shared.setShare(id: runID, shareURL: result.url, shareID: result.shareID)
            return result
        } catch {
            return nil
        }
    }

    /// App-open sweep: share anything that missed its auto-share (background
    /// runs cut short, network failures). One at a time, quiet.
    @MainActor
    static func sweepUnshared() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PIKA_MOCK"] == "1" { return }
        #endif
        for run in RunStore.shared.runs where run.shareURL == nil {
            _ = await ensureShared(runID: run.id)
        }
    }

    static func upload(run: SavedRun, progress: @MainActor @escaping (String) -> Void) async throws -> ShareResult {
        let t0 = Date()
        Analytics.capture("share_upload_started", ["pages": run.selections.count + 1])
        do {
            let result = try await uploadInner(run: run)
            Analytics.capture("share_upload_completed", [
                "pages": run.selections.count + 1,
                "seconds": Date().timeIntervalSince(t0),
                "bytes": result.bytes,
            ])
            return result.share
        } catch {
            Analytics.capture("share_upload_failed", [
                "seconds": Date().timeIntervalSince(t0),
                "error": String(describing: error).prefix(200).description,
            ])
            throw error
        }
    }

    private static func uploadInner(run: SavedRun) async throws -> (share: ShareResult, bytes: Int) {
        // Page 0 is the cover; book pages follow in order.
        let ordered = [run.coverAssetID] + run.selections.sorted { $0.page < $1.page }.map(\.assetID)
        // 1600px derivatives (not full-res originals) — much cheaper when the
        // library is iCloud-optimized.
        let images = await AssetLoader.load(ids: Array(Set(ordered)), size: CGSize(width: 1600, height: 1600))

        struct CreateResp: Codable {
            let bookId: String
            let shareId: String
            let uploadUrls: [String]
        }
        let create: CreateResp = try await postJSON(path: "/create-book", body: [
            "title": run.title,
            "monthLabel": run.monthLabel,
            "deviceName": UIDevice.current.name,
            "pageCount": ordered.count,
        ])

        struct UploadResp: Codable { let storageId: String }
        // Encode + upload pages concurrently (5 in flight) instead of one by one.
        let jpegs: [(page: Int, url: String, data: Data)] = try ordered.enumerated().map { i, assetID in
            guard let img = images[assetID],
                  let jpeg = normalized(img).jpegData(compressionQuality: 0.8) else {
                throw PipelineError.message("couldn't load photo for page \(i)")
            }
            return (i, create.uploadUrls[i], jpeg)
        }
        let totalBytes = jpegs.reduce(0) { $0 + $1.data.count }
        let pages: [[String: Any]] = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results: [Int: String] = [:]
            var iterator = jpegs.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let job = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    var req = URLRequest(url: URL(string: job.url)!)
                    req.httpMethod = "POST"
                    req.setValue("image/jpeg", forHTTPHeaderField: "content-type")
                    req.httpBody = job.data
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        throw PipelineError.message("page upload failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1))")
                    }
                    let up = try JSONDecoder().decode(UploadResp.self, from: data)
                    return (job.page, up.storageId)
                }
            }
            for _ in 0..<5 { addNext() }
            while inFlight > 0 {
                guard let (page, storageId) = try await group.next() else { break }
                inFlight -= 1
                results[page] = storageId
                addNext()
            }
            return results.sorted { $0.key < $1.key }.map { ["page": $0.key, "storageId": $0.value] }
        }

        struct OkResp: Codable { let ok: Bool }
        let _: OkResp = try await postJSON(path: "/finalize-book", body: [
            "bookId": create.bookId,
            "pages": pages,
        ])
        return (ShareResult(url: shareBase + create.shareId, shareID: create.shareId), totalBytes)
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

    /// Bake orientation into pixels: UIImage's EXIF-style orientation flag is
    /// unreliable once the JPEG leaves the device (web browsers saw sideways
    /// photos). Rendering through UIGraphicsImageRenderer always outputs .up.
    private static func normalized(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: img.size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
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
