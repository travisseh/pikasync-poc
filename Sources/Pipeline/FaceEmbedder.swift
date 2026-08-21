import CoreGraphics
import CoreML
import Foundation
import Vision

/// Already-aligned 112x112 face crop ready for embedding.
struct FaceCrop {
    let image: CGImage
}

/// ArcFace-class face identity embedder backed by a Core ML port of
/// InsightFace buffalo_s (w600k_mbf). Input: aligned 112x112 RGB crop.
/// Output: 512-dim L2-normalized embedding. Cosine similarity between
/// embeddings measures identity: same person typically > 0.5, different
/// people typically < 0.25.
enum FaceEmbedder {
    /// Override before first use (tests / CLI). Defaults to the bundled
    /// compiled model FaceEmbedding.mlmodelc.
    static var modelURL: URL?

    private static let inputSize = 112

    // Canonical ArcFace 112x112 5-point template.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),  // left eye (image-left)
        CGPoint(x: 73.5318, y: 51.5014),  // right eye
        CGPoint(x: 56.0252, y: 71.7366),  // nose tip
        CGPoint(x: 41.5493, y: 92.3655),  // mouth left
        CGPoint(x: 70.7299, y: 92.2041),  // mouth right
    ]

    private static let model: MLModel? = {
        let url = modelURL ?? Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc")
        guard let url else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    // MARK: - Embedding

    /// Embeds an aligned 112x112 crop. Returns a 512-dim L2-normalized vector.
    static func embed(_ crop: CGImage) -> [Float]? {
        guard let model else { return nil }
        guard let pixels = rgbaBytes(of: crop) else { return nil }
        guard let input = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32) else { return nil }

        // RGBA interleaved -> CHW float32, (p - 127.5) / 127.5
        let n = inputSize * inputSize
        let ptr = input.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<n {
            ptr[i]         = (Float32(pixels[i * 4])     - 127.5) / 127.5
            ptr[n + i]     = (Float32(pixels[i * 4 + 1]) - 127.5) / 127.5
            ptr[2 * n + i] = (Float32(pixels[i * 4 + 2]) - 127.5) / 127.5
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input": input]),
              let out = try? model.prediction(from: provider),
              let emb = out.featureValue(for: "embedding")?.multiArrayValue
        else { return nil }

        var v = [Float](repeating: 0, count: 512)
        let outPtr = emb.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<512 { v[i] = outPtr[i] }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }

    // MARK: - Alignment

    /// Produces the canonical ArcFace 112x112 aligned crop from a full image
    /// and a Vision face observation with landmarks. Uses 5-point similarity
    /// alignment (eyes, nose tip, mouth corners) when available, degrading to
    /// eyes+nose or eyes-only if Vision omits regions.
    static func alignedCrop(from fullImage: CGImage, landmarks obs: VNFaceObservation) -> CGImage? {
        guard let lm = obs.landmarks else { return nil }
        let w = fullImage.width, h = fullImage.height
        let size = CGSize(width: w, height: h)

        // pointsInImage gives image pixels with a bottom-left origin; flip to
        // the top-left origin the template uses.
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: CGFloat(h) - p.y) }
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let pts = region.pointsInImage(imageSize: size)
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return pixel(CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count)))
        }

        guard let eyeA = centroid(lm.leftPupil) ?? centroid(lm.leftEye),
              let eyeB = centroid(lm.rightPupil) ?? centroid(lm.rightEye)
        else { return nil }

        // Nose tip: last point of the nose crest when present, else nose centroid.
        var noseTip: CGPoint?
        if let crest = lm.noseCrest, crest.pointCount > 0 {
            noseTip = pixel(crest.pointsInImage(imageSize: size).last!)
        } else {
            noseTip = centroid(lm.nose)
        }

        let lipPoints: [CGPoint] = {
            guard let lips = lm.outerLips, lips.pointCount >= 2 else { return [] }
            return lips.pointsInImage(imageSize: size).map(pixel)
        }()

        // Vision's left/right eyes are the subject's, and the face may be
        // rolled arbitrarily, so image-space sorting is unreliable. Try both
        // eye-to-template assignments and keep the fit with the lower
        // residual; the mirrored assignment cannot be fit by a rotation-only
        // similarity, so the correct one wins.
        func build(eyeL: CGPoint, eyeR: CGPoint) -> (CGAffineTransform, CGFloat)? {
            var src: [CGPoint] = [eyeL, eyeR]
            var dst: [CGPoint] = [template[0], template[1]]
            if let noseTip { src.append(noseTip); dst.append(template[2]) }
            if !lipPoints.isEmpty {
                // Mouth corners: extreme lips points along the eye axis.
                let ux = eyeR.x - eyeL.x, uy = eyeR.y - eyeL.y
                let mouthL = lipPoints.min { $0.x * ux + $0.y * uy < $1.x * ux + $1.y * uy }!
                let mouthR = lipPoints.max { $0.x * ux + $0.y * uy < $1.x * ux + $1.y * uy }!
                src.append(mouthL); dst.append(template[3])
                src.append(mouthR); dst.append(template[4])
            }
            guard let t = similarityTransform(from: src, to: dst) else { return nil }
            var residual: CGFloat = 0
            for i in src.indices {
                let p = src[i].applying(t)
                residual += hypot(p.x - dst[i].x, p.y - dst[i].y)
            }
            return (t, residual / CGFloat(src.count))
        }

        let candidates = [build(eyeL: eyeA, eyeR: eyeB), build(eyeL: eyeB, eyeR: eyeA)]
            .compactMap { $0 }
        guard var best = candidates.min(by: { $0.1 < $1.1 }) else { return nil }

        // If landmarks disagree badly (occlusion, extreme pose), fall back to
        // an exact eyes-only similarity; the eyes are Vision's most reliable
        // points. Threshold: mean residual > 8px in the 112x112 frame.
        if best.1 > 8 {
            let eyesOnly = [
                similarityTransform(from: [eyeA, eyeB], to: [template[0], template[1]]),
                similarityTransform(from: [eyeB, eyeA], to: [template[0], template[1]]),
            ].compactMap { $0 }
            // Disambiguate mirror with the nose: it must land below the eyes.
            let pick = eyesOnly.first { t in
                guard let noseTip else { return true }
                return noseTip.applying(t).y > template[0].y
            } ?? eyesOnly.first
            if let pick { best = (pick, 0) }
        }
        return warp(fullImage, transform: best.0)
    }

    /// Least-squares similarity transform (rotation + uniform scale +
    /// translation, no reflection) mapping src points onto dst points.
    /// Equivalent to Umeyama without the reflection branch; exact for 2
    /// points, least-squares for more.
    private static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        let n = CGFloat(src.count)
        guard src.count >= 2, src.count == dst.count else { return nil }

        var mx: CGFloat = 0, my: CGFloat = 0, mu: CGFloat = 0, mv: CGFloat = 0
        for i in src.indices {
            mx += src[i].x; my += src[i].y; mu += dst[i].x; mv += dst[i].y
        }
        mx /= n; my /= n; mu /= n; mv /= n

        var d: CGFloat = 0       // Σ(x'² + y'²)
        var ac: CGFloat = 0      // Σ(x'u' + y'v')
        var bc: CGFloat = 0      // Σ(x'v' - y'u')
        for i in src.indices {
            let x = src[i].x - mx, y = src[i].y - my
            let u = dst[i].x - mu, v = dst[i].y - mv
            d += x * x + y * y
            ac += x * u + y * v
            bc += x * v - y * u
        }
        guard d > 1e-6 else { return nil }
        let a = ac / d, b = bc / d
        let tx = mu - a * mx + b * my
        let ty = mv - b * mx - a * my
        // CG convention: x' = a*x + c*y + tx, y' = b*x + d*y + ty
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// Warps the full image through a top-left-origin similarity transform
    /// into a 112x112 RGB crop.
    private static func warp(_ image: CGImage, transform: CGAffineTransform) -> CGImage? {
        let side = inputSize
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high

        // Destination: switch to top-left coordinates.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(transform)
        // Source: CGContext.draw places the image y-up; flip so the transform
        // above sees top-left source pixel coordinates.
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - Pixel access

    private static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let side = inputSize
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &bytes, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes
    }

    // MARK: - Similarity

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }
}
