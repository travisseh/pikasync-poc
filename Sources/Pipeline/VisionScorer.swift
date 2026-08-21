import Foundation
import Vision
import Photos
import UIKit

/// Per-photo scores from Apple's on-device Vision APIs — the same signals the
/// desktop pipeline's visiontool CLI produced on the Mac.
struct PhotoScore: Identifiable {
    let id: String            // PHAsset localIdentifier
    let date: Date?
    var aesthetics: Float = 0
    var isUtility: Bool = false
    var faceQuality: Float = 0    // best face in frame
    var nFaces: Int = 0
    var featurePrint: [Float]? = nil  // normalized
    var finalScore: Float = 0
    var shortlistIndex: Int? = nil
    var personIDs: Set<UUID> = []     // PeopleStore cluster ids
}

enum VisionScorer {
    static func score(assetID: String, date: Date?, cgImage: CGImage) -> (PhotoScore, [VNFaceObservation]) {
        var s = PhotoScore(id: assetID, date: date)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let faceReq = VNDetectFaceCaptureQualityRequest()
        let landmarksReq = VNDetectFaceLandmarksRequest()
        let fpReq = VNGenerateImageFeaturePrintRequest()
        var requests: [VNRequest] = [faceReq, landmarksReq, fpReq]

        var aesReq: VNCalculateImageAestheticsScoresRequest? = nil
        if #available(iOS 18.0, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            aesReq = r
            requests.append(r)
        }

        try? handler.perform(requests)

        if let faces = faceReq.results {
            s.nFaces = faces.count
            s.faceQuality = faces.compactMap { $0.faceCaptureQuality }.max() ?? 0
        }
        if let obs = fpReq.results?.first as? VNFeaturePrintObservation {
            s.featurePrint = normalized(floats(from: obs))
        }
        if #available(iOS 18.0, *), let obs = aesReq?.results?.first {
            s.aesthetics = obs.overallScore   // -1...1
            s.isUtility = obs.isUtility
        }

        // Faces eligible for identity embedding: big enough to matter (drops
        // background strangers), decent capture quality (drops texture false
        // positives and motion blur), and with landmarks (alignment needs them).
        let qualityFaces = faceReq.results ?? []
        let eligible = (landmarksReq.results ?? []).filter { lm in
            guard lm.boundingBox.width >= 0.05, lm.landmarks != nil else { return false }
            let q = qualityFaces
                .filter { iou($0.boundingBox, lm.boundingBox) > 0.3 }
                .compactMap { $0.faceCaptureQuality }.max() ?? 0
            return q >= 0.15
        }
        return (s, eligible)
    }

    /// Lean face-only pass for people discovery (no aesthetics/feature print).
    static func facesOnly(cgImage: CGImage) -> [VNFaceObservation] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let faceReq = VNDetectFaceCaptureQualityRequest()
        let landmarksReq = VNDetectFaceLandmarksRequest()
        try? handler.perform([faceReq, landmarksReq])
        let qualityFaces = faceReq.results ?? []
        return (landmarksReq.results ?? []).filter { lm in
            guard lm.boundingBox.width >= 0.05, lm.landmarks != nil else { return false }
            let q = qualityFaces
                .filter { iou($0.boundingBox, lm.boundingBox) > 0.3 }
                .compactMap { $0.faceCaptureQuality }.max() ?? 0
            return q >= 0.15
        }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }

    private static func floats(from obs: VNFeaturePrintObservation) -> [Float] {
        guard obs.elementType == .float else { return [] }
        let count = obs.elementCount
        var arr = [Float](repeating: 0, count: count)
        arr.withUnsafeMutableBytes { buf in
            obs.data.copyBytes(to: buf)
        }
        return arr
    }

    private static func normalized(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty else { return nil }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }
}
