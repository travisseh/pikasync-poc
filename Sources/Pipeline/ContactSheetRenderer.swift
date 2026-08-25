import UIKit

/// 4x4 labeled grids — same format the desktop pipeline fed the judge:
/// each cell shows the photo with "[index] M/d faces:N" printed under it.
enum ContactSheetRenderer {
    static let cols = 4, rows = 4
    static let cell: CGFloat = 420
    static let labelH: CGFloat = 44

    static func render(scores: [PhotoScore], thumbs: [String: UIImage]) -> [UIImage] {
        let perSheet = cols * rows
        let df = DateFormatter()
        df.dateFormat = "M/d"
        var out: [UIImage] = []
        for chunkStart in stride(from: 0, to: scores.count, by: perSheet) {
            let chunk = Array(scores[chunkStart..<min(chunkStart + perSheet, scores.count)])
            let size = CGSize(width: cell * CGFloat(cols), height: (cell + labelH) * CGFloat(rows))
            // 1x pixels: the default format uses the device's 3x screen scale, which
            // makes each sheet ~9x the bytes and blows Vercel's 4.5MB request cap.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let img = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                for (i, s) in chunk.enumerated() {
                    let col = i % cols, row = i / cols
                    let x = CGFloat(col) * cell
                    let y = CGFloat(row) * (cell + labelH)
                    if let t = thumbs[s.id] {
                        t.draw(in: CGRect(x: x, y: y, width: cell, height: cell))
                    }
                    let dateStr = s.date.map { df.string(from: $0) } ?? "?"
                    let names = s.personIDs.compactMap { PeopleStore.shared.name(of: $0) }
                        .filter { !$0.hasPrefix("Person ") }
                        .prefix(2).joined(separator: ",")
                    var label = "[\(s.shortlistIndex ?? -1)] \(dateStr) faces:\(s.nFaces)"
                    if !names.isEmpty { label += " \(names)" }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .semibold),
                        .foregroundColor: UIColor.black,
                    ]
                    label.draw(at: CGPoint(x: x + 8, y: y + cell + 8), withAttributes: attrs)
                }
            }
            out.append(img)
        }
        return out
    }
}
