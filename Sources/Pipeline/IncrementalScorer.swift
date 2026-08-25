import Foundation
import Photos
import UIKit

/// Incremental per-month scoring store. Background refresh wakes (~30s budget)
/// score a chunk of unscored photos and checkpoint to Documents/scores-yyyy-MM.json;
/// over a few daily wakes a whole month drains. The interactive pipeline uses the
/// same store, so foreground runs pre-pay the background's scoring work.
@MainActor
enum IncrementalScorer {
    struct ChunkResult {
        let newlyScored: Int
        let remaining: Int
        let total: Int
        var complete: Bool { remaining == 0 }
    }

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func storeURL(month: Date) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scores-\(monthFmt.string(from: month)).json")
    }

    static func loadScores(month: Date) -> [PhotoScore] {
        guard let data = try? Data(contentsOf: storeURL(month: month)),
              let scores = try? JSONDecoder().decode([PhotoScore].self, from: data) else { return [] }
        return scores
    }

    private static func save(_ scores: [PhotoScore], month: Date) {
        if let data = try? JSONEncoder().encode(scores) {
            try? data.write(to: storeURL(month: month))
        }
    }

    /// All non-screenshot image assets in the month, chronological.
    static func monthAssets(_ month: Date) -> [PHAsset] {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in
            if !a.mediaSubtypes.contains(.photoScreenshot) { assets.append(a) }
        }
        return assets
    }

    /// Score up to `budget` seconds of this month's unscored photos, checkpointing
    /// after every photo so an expired background task loses nothing.
    /// budget == nil means run to completion (interactive path).
    static func scoreChunk(month: Date, budget: TimeInterval?, progress: ((Int, Int) -> Void)? = nil) async -> ChunkResult {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return ChunkResult(newlyScored: 0, remaining: -1, total: -1)
        }

        let assets = monthAssets(month)
        var scores = loadScores(month: month)
        let doneIDs = Set(scores.map(\.id))
        let todo = assets.filter { !doneIDs.contains($0.localIdentifier) }
        guard !todo.isEmpty else {
            return ChunkResult(newlyScored: 0, remaining: 0, total: assets.count)
        }

        let t0 = Date()
        var newCount = 0
        for asset in todo {
            if let b = budget, Date().timeIntervalSince(t0) >= b { break }
            if let s = await scoreOne(asset: asset) {
                scores.append(s)
            } else {
                // Unloadable (e.g. iCloud fetch failed offline): record a stub so
                // we don't retry it forever and the month can still close.
                scores.append(PhotoScore(id: asset.localIdentifier, date: asset.creationDate, isUtility: true))
            }
            newCount += 1
            if newCount % 5 == 0 { save(scores, month: month) }
            progress?(scores.count, assets.count)
        }
        save(scores, month: month)
        PeopleStore.shared.save()
        return ChunkResult(newlyScored: newCount, remaining: assets.count - scores.count, total: assets.count)
    }

    /// Single-photo scoring: Vision + face identity. Same pattern the original
    /// monolithic pipeline used, extracted so background chunks and the
    /// interactive run share one implementation.
    static func scoreOne(asset: PHAsset) async -> PhotoScore? {
        let mgr = PHImageManager.default()
        let reqOpts = PHImageRequestOptions()
        reqOpts.isSynchronous = true
        reqOpts.deliveryMode = .highQualityFormat
        reqOpts.isNetworkAccessAllowed = true
        reqOpts.resizeMode = .fast
        let target = CGSize(width: 1024, height: 1024)
        let people = PeopleStore.shared
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    var out: PhotoScore? = nil
                    mgr.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: reqOpts) { img, _ in
                        if let cg = img?.cgImage {
                            var (s, faceObs) = VisionScorer.score(assetID: asset.localIdentifier, date: asset.creationDate, cgImage: cg)
                            if FaceIDBridge.isAvailable {
                                for face in faceObs.prefix(6) {
                                    if let (emb, crop) = FaceIDBridge.embed(fullImage: cg, face: face) {
                                        let id = DispatchQueue.main.sync { people.assign(embedding: emb, crop: crop) }
                                        s.personIDs.insert(id)
                                    }
                                }
                            }
                            out = s
                        }
                    }
                    cont.resume(returning: out)
                }
            }
        }
    }
}
