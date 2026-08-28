import Foundation
import Photos
import UIKit

/// First-run setup: scan recent photos, detect + embed faces, and populate
/// PeopleStore so the user can pick who books center on. The onboarding path
/// (`limit: 200`) runs the full pipeline scorer per photo, so it also fills
/// the incremental score store as a side effect.
@MainActor
final class PeopleScanner: ObservableObject {
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var statusText = ""

    static let scannedKey = "peopleScanDone"
    var hasScanned: Bool { UserDefaults.standard.bool(forKey: Self.scannedKey) }

    /// Default sweep is ~6 months; onboarding passes `limit: 200` so the
    /// first-run scan stays fast regardless of how dense the library is
    /// (the People tab's Rescan deepens it later).
    func scan(daysBack: Int = 183, limit: Int? = nil) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != .authorized && status != .limited {
            await SyncEngine.requestPermission()
        }

        let opts = PHFetchOptions()
        if let limit {
            // Most recent N photos regardless of date.
            opts.fetchLimit = limit
        } else {
            let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())!
            opts.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        }
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in
            if !a.mediaSubtypes.contains(.photoScreenshot) { assets.append(a) }
        }

        let people = PeopleStore.shared
        if limit != nil {
            // Onboarding path: run the FULL pipeline scorer on each photo.
            // One pass populates the face clusters (scoreOne assigns embeddings
            // through PeopleStore, so personIDs match the clusters the user is
            // about to star) AND pre-pays the score store, so "Make my first
            // book" starts partially scored and finishes faster.
            var pending: [String: (month: Date, scores: [PhotoScore])] = [:]
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM"
            var alreadyScored: [String: Set<String>] = [:]
            for (i, asset) in assets.enumerated() {
                let month = asset.creationDate ?? Date()
                let key = fmt.string(from: month)
                if alreadyScored[key] == nil {
                    alreadyScored[key] = Set(IncrementalScorer.loadScores(month: month).map(\.id))
                }
                if alreadyScored[key]!.contains(asset.localIdentifier) == false,
                   let s = await IncrementalScorer.scoreOne(asset: asset) {
                    pending[key, default: (month, [])].scores.append(s)
                    alreadyScored[key]!.insert(asset.localIdentifier)
                }
                if i % 5 == 0 {
                    progress = Double(i + 1) / Double(max(1, assets.count))
                    statusText = "Scanning faces \(i + 1)/\(assets.count)"
                    for (k, v) in pending where v.scores.count >= 10 {
                        IncrementalScorer.merge(v.scores, month: v.month)
                        pending[k]?.scores.removeAll()
                    }
                }
            }
            for (_, v) in pending { IncrementalScorer.merge(v.scores, month: v.month) }
        } else {
            let mgr = PHImageManager.default()
            let reqOpts = PHImageRequestOptions()
            reqOpts.isSynchronous = true
            reqOpts.deliveryMode = .highQualityFormat
            reqOpts.isNetworkAccessAllowed = true
            reqOpts.resizeMode = .fast
            let target = CGSize(width: 900, height: 900)

            for (i, asset) in assets.enumerated() {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        autoreleasepool {
                            mgr.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: reqOpts) { img, _ in
                                guard let cg = img?.cgImage else { return }
                                for face in VisionScorer.facesOnly(cgImage: cg).prefix(6) {
                                    if let (emb, crop) = FaceIDBridge.embed(fullImage: cg, face: face) {
                                        _ = DispatchQueue.main.sync { people.assign(embedding: emb, crop: crop) }
                                    }
                                }
                            }
                            cont.resume()
                        }
                    }
                }
                if i % 10 == 0 {
                    progress = Double(i + 1) / Double(max(1, assets.count))
                    statusText = "Scanning faces \(i + 1)/\(assets.count)"
                }
            }
        }
        people.save()
        UserDefaults.standard.set(true, forKey: Self.scannedKey)
        statusText = "Found \(people.clusters.count) people in \(assets.count) photos"
        progress = 1
    }
}
