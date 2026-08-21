import Foundation
import UIKit

/// Persisted face-identity clusters — "who is in this library."
/// Stored in Documents/people.json, editable in PeoplePickerView, and applied
/// to every photobook generation (required people guaranteed + balanced,
/// excluded people dropped).
struct PersonCluster: Codable, Identifiable {
    enum Role: String, Codable, CaseIterable {
        case neutral, required, excluded
    }
    let id: UUID
    var name: String
    var role: Role = .neutral
    var centroid: [Float]     // running-mean, L2-normalized
    var count: Int
    var repCropPNG: Data?
}

final class PeopleStore: ObservableObject {
    static let shared = PeopleStore()
    // Same-person cosines measured on this library run 0.38-0.65; different
    // adults < 0.05, worst adult-vs-baby 0.24. 0.32 splits those cleanly.
    static let matchThreshold: Float = 0.32

    @Published var clusters: [PersonCluster] = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("people.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode([PersonCluster].self, from: data) else { return }
        clusters = c
    }

    func save() {
        if let data = try? JSONEncoder().encode(clusters) {
            try? data.write(to: url)
        }
    }

    /// Assign one face embedding to a cluster (creating one if it's a new person).
    /// Returns the cluster id.
    func assign(embedding: [Float], crop: UIImage?) -> UUID {
        var bestIdx = -1
        var bestSim: Float = 0
        for (i, c) in clusters.enumerated() {
            let sim = VisionScorer.cosine(embedding, c.centroid)
            if sim > bestSim { bestSim = sim; bestIdx = i }
        }
        if bestIdx >= 0 && bestSim >= Self.matchThreshold {
            var c = clusters[bestIdx]
            let n = Float(c.count)
            var merged = zip(c.centroid, embedding).map { ($0 * n + $1) / (n + 1) }
            let norm = sqrt(merged.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { merged = merged.map { $0 / norm } }
            c.centroid = merged
            c.count += 1
            if c.repCropPNG == nil, let crop { c.repCropPNG = crop.pngData() }
            clusters[bestIdx] = c
            return c.id
        }
        let fresh = PersonCluster(id: UUID(), name: "Person \(clusters.count + 1)",
                                  centroid: embedding, count: 1,
                                  repCropPNG: crop?.pngData())
        clusters.append(fresh)
        return fresh.id
    }

    func role(of id: UUID) -> PersonCluster.Role {
        clusters.first { $0.id == id }?.role ?? .neutral
    }

    func name(of id: UUID) -> String? {
        clusters.first { $0.id == id }?.name
    }

    var requiredIDs: Set<UUID> { Set(clusters.filter { $0.role == .required }.map(\.id)) }
    var excludedIDs: Set<UUID> { Set(clusters.filter { $0.role == .excluded }.map(\.id)) }
}
