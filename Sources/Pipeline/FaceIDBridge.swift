import Foundation
import Vision
import UIKit

/// Seam over the on-device ArcFace embedder. Internals get wired to the
/// converted Core ML model (see scratchpad/ios-face-embedder); until then
/// isAvailable=false and the pipeline runs without identity clustering.
enum FaceIDBridge {
    static let isAvailable = false

    /// 512-dim L2-normalized identity embedding for one detected face,
    /// plus a small crop for the picker UI.
    static func embed(fullImage: CGImage, face: VNFaceObservation) -> (embedding: [Float], crop: UIImage)? {
        return nil
    }
}
