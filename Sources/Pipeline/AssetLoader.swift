import Photos
import UIKit

enum AssetLoader {
    static func load(ids: [String], size: CGSize) async -> [String: UIImage] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
        let mgr = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var out: [String: UIImage] = [:]
                for id in ids {
                    guard let a = byID[id] else { continue }
                    autoreleasepool {
                        mgr.requestImage(for: a, targetSize: size, contentMode: .aspectFill, options: opts) { img, _ in
                            if let img { out[id] = img }
                        }
                    }
                }
                cont.resume(returning: out)
            }
        }
    }
}
