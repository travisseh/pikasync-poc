import Foundation
import Photos
import UIKit

/// First-run setup: walk the last 6 months of photos, detect + embed faces,
/// and populate PeopleStore so the user can name/star their family before
/// generating books.
@MainActor
final class PeopleScanner: ObservableObject {
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var statusText = ""

    static let scannedKey = "peopleScanDone"
    var hasScanned: Bool { UserDefaults.standard.bool(forKey: Self.scannedKey) }

    func scan(monthsBack: Int = 6) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != .authorized && status != .limited {
            await SyncEngine.requestPermission()
        }

        let cal = Calendar.current
        let start = cal.date(byAdding: .month, value: -monthsBack, to: Date())!
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in
            if !a.mediaSubtypes.contains(.photoScreenshot) { assets.append(a) }
        }

        let mgr = PHImageManager.default()
        let reqOpts = PHImageRequestOptions()
        reqOpts.isSynchronous = true
        reqOpts.deliveryMode = .highQualityFormat
        reqOpts.isNetworkAccessAllowed = true
        reqOpts.resizeMode = .fast
        let target = CGSize(width: 900, height: 900)
        let people = PeopleStore.shared

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
        people.save()
        UserDefaults.standard.set(true, forKey: Self.scannedKey)
        statusText = "Found \(people.clusters.count) people in \(assets.count) photos"
        progress = 1
    }
}
