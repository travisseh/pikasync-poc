import Foundation
import UIKit

/// Every completed pipeline run is saved so past books stay viewable.
struct SavedRun: Codable, Identifiable {
    struct Selection: Codable {
        let assetID: String
        let page: Int
        var caption: String? = nil  // legacy runs only; new books have no captions
    }
    struct Stage: Codable {
        let name: String
        let detail: String
        let seconds: Double
    }
    let id: UUID
    let createdAt: Date
    let monthLabel: String
    let title: String
    let coverAssetID: String
    let selections: [Selection]
    let totalSeconds: Double
    let judgeInfo: String
    var coverThumbJPEG: Data?
    var shareURL: String? = nil  // cached share link once uploaded
    var shareID: String? = nil   // Convex shareId (feedback capability token)
    var stages: [Stage]? = nil   // pipeline details, viewable from the "…" menu
}

final class RunStore: ObservableObject {
    static let shared = RunStore()
    @Published var runs: [SavedRun] = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runs.json")
    }

    init() {
        if let data = try? Data(contentsOf: url),
           let r = try? JSONDecoder().decode([SavedRun].self, from: data) {
            runs = r.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func add(_ run: SavedRun) {
        runs.insert(run, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        runs.removeAll { $0.id == id }
        save()
    }

    func setShare(id: UUID, shareURL: String, shareID: String) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].shareURL = shareURL
        runs[i].shareID = shareID
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(runs) {
            try? data.write(to: url)
        }
    }
}
