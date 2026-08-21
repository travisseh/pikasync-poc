import Foundation
import Vision
import UIKit

/// Seam over the on-device ArcFace embedder (Core ML port of w600k_mbf).
/// Alignment + inference live in FaceEmbedder.swift.
enum FaceIDBridge {
    static let isAvailable = true

    /// 512-dim L2-normalized identity embedding for one detected face,
    /// plus the aligned 112x112 crop for the picker UI.
    static func embed(fullImage: CGImage, face: VNFaceObservation) -> (embedding: [Float], crop: UIImage)? {
        guard let crop = FaceEmbedder.alignedCrop(from: fullImage, landmarks: face),
              let emb = FaceEmbedder.embed(crop) else { return nil }
        return (emb, UIImage(cgImage: crop))
    }
}
