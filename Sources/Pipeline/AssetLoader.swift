import Photos
import UIKit

enum AssetLoader {
    static func load(ids: [String], size: CGSize) async -> [String: UIImage] {
        #if DEBUG
        // Simulator design-iteration path: "mock:<file>" ids resolve to
        // Documents/mock-photos/<file> instead of PhotoKit (see MockSeeder).
        if ids.contains(where: { $0.hasPrefix("mock:") }) {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mock-photos")
            var out: [String: UIImage] = [:]
            for id in ids where id.hasPrefix("mock:") {
                let file = String(id.dropFirst(5))
                if let img = UIImage(contentsOfFile: dir.appendingPathComponent(file).path) {
                    out[id] = img
                }
            }
            return out
        }
        #endif
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
