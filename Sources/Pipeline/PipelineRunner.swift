import Foundation
import Photos
import UIKit

/// On-device port of the desktop curation pipeline, scoped to one month:
/// ingest -> Vision scoring -> burst dedup -> rank -> coverage shortlist ->
/// contact sheets -> LLM judge -> book. Instrumented per stage.
@MainActor
final class PipelineRunner: ObservableObject {
    struct StageTime: Identifiable {
        let id = UUID()
        let name: String
        let seconds: Double
        let detail: String
    }

    @Published var status = "idle"
    @Published var progress: Double = 0
    @Published var stageTimes: [StageTime] = []
    @Published var sheets: [UIImage] = []
    @Published var shortlist: [PhotoScore] = []
    @Published var book: BookResult? = nil
    @Published var judgeInfo = ""
    @Published var errorText: String? = nil
    @Published var running = false

    // Month-scale tuning (desktop used 120/18 for a full year)
    static let shortlistTarget = 48
    static let noFaceQuota = 7
    static let bookSize = 20
    static let burstWindowSec: TimeInterval = 90
    static let burstSim: Float = 0.92
    static let sceneSim: Float = 0.82
    static let sceneWindowHours: TimeInterval = 6

    func run(month: Date) async {
        running = true
        errorText = nil
        book = nil
        sheets = []
        stageTimes = []
        defer { running = false }

        do {
            // Stage 1: ingest — fetch assets for the month
            var t0 = Date()
            let cal = Calendar.current
            let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let fetch = PHAsset.fetchAssets(with: .image, options: opts)
            var assets: [PHAsset] = []
            var screenshotsDropped = 0
            fetch.enumerateObjects { a, _, _ in
                if a.mediaSubtypes.contains(.photoScreenshot) { screenshotsDropped += 1 } else { assets.append(a) }
            }
            record("ingest", since: t0, "\(assets.count) photos in month (\(screenshotsDropped) screenshots dropped)")
            guard assets.count >= 8 else {
                throw PipelineError.message("Only \(assets.count) photos in that month — pick a busier one")
            }

            // Stage 2: Vision scoring
            t0 = Date()
            status = "scoring 0/\(assets.count)"
            var scores: [PhotoScore] = []
            let mgr = PHImageManager.default()
            let reqOpts = PHImageRequestOptions()
            reqOpts.isSynchronous = true
            reqOpts.deliveryMode = .highQualityFormat
            reqOpts.isNetworkAccessAllowed = true  // pull from iCloud if needed
            reqOpts.resizeMode = .fast
            let target = CGSize(width: 1024, height: 1024)
            let people = PeopleStore.shared
            for (i, asset) in assets.enumerated() {
                let score: PhotoScore? = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        autoreleasepool {
                            var out: PhotoScore? = nil
                            mgr.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: reqOpts) { img, _ in
                                if let cg = img?.cgImage {
                                    var (s, faceObs) = VisionScorer.score(assetID: asset.localIdentifier, date: asset.creationDate, cgImage: cg)
                                    if FaceIDBridge.isAvailable {
                                        for face in faceObs.prefix(6) {
                                            if let (emb, crop) = FaceIDBridge.embed(fullImage: cg, face: face) {
                                                let id = DispatchQueue.main.sync { people.assign(embedding: emb, crop: crop) }
                                                s.personIDs.insert(id)
                                            }
                                        }
                                    }
                                    out = s
                                }
                            }
                            cont.resume(returning: out)
                        }
                    }
                }
                if let s = score { scores.append(s) }
                if i % 10 == 0 {
                    status = "scoring \(i + 1)/\(assets.count)"
                    progress = Double(i + 1) / Double(assets.count)
                }
            }
            record("vision scoring", since: t0, String(format: "%d scored, %.2fs/photo", scores.count, Date().timeIntervalSince(t0) / Double(max(1, scores.count))))

            // Stage 3: quality gate + burst dedup (+ excluded-people drop)
            t0 = Date()
            people.save()
            let excluded = people.excludedIDs
            let kept = scores.filter { !$0.isUtility && $0.personIDs.isDisjoint(with: excluded) }
            let excludedDrops = scores.filter { !$0.personIDs.isDisjoint(with: excluded) }.count
            var deduped: [PhotoScore] = []
            for s in kept.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
                if let last = deduped.last, let d1 = last.date, let d2 = s.date,
                   d2.timeIntervalSince(d1) <= Self.burstWindowSec,
                   let f1 = last.featurePrint, let f2 = s.featurePrint,
                   VisionScorer.cosine(f1, f2) >= Self.burstSim {
                    // same burst: keep the better one
                    if composite(s) > composite(last) { deduped[deduped.count - 1] = s }
                } else {
                    deduped.append(s)
                }
            }
            record("gate + dedup", since: t0, "\(scores.count - kept.count - excludedDrops) utility + \(excludedDrops) excluded-person dropped, \(kept.count - deduped.count) burst twins collapsed, \(deduped.count) remain")

            // Stage 4: rank + coverage shortlist (week floors instead of month floors)
            t0 = Date()
            var ranked = deduped
            for i in ranked.indices { ranked[i].finalScore = composite(ranked[i]) }
            ranked.sort { $0.finalScore > $1.finalScore }
            var chosen = shortlistSelect(ranked: ranked)
            chosen.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            for i in chosen.indices { chosen[i].shortlistIndex = i }
            shortlist = chosen
            let noFace = chosen.filter { $0.nFaces == 0 }.count
            record("shortlist", since: t0, "\(chosen.count) chosen, \(noFace) no-face")

            // Stage 5: contact sheets
            t0 = Date()
            status = "rendering sheets"
            let images = await loadThumbs(ids: chosen.map(\.id), size: CGSize(width: 420, height: 420))
            sheets = ContactSheetRenderer.render(scores: chosen, thumbs: images)
            record("contact sheets", since: t0, "\(sheets.count) sheets of \(chosen.count) photos")

            // Stage 6: LLM judge
            t0 = Date()
            status = "judging (claude-sonnet-5)"
            let monthName = DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .none)
            let result = try await JudgeClient.judge(sheets: sheets, monthLabel: monthName, count: min(Self.bookSize, chosen.count), maxIndex: chosen.count - 1)
            record("LLM judge", since: t0, result.usageSummary)
            judgeInfo = result.usageSummary
            book = result.book
            status = "done — \(result.book.selections.count)-photo book ready"
        } catch {
            errorText = "\(error)"
            status = "failed"
        }
    }

    private func composite(_ s: PhotoScore) -> Float {
        // Mirrors select.py: aesthetics dominates, face quality bonus.
        var v = 0.6 * s.aesthetics + 0.15 * s.faceQuality
        if s.nFaces > 0 { v += 0.1 }
        return v
    }

    private func shortlistSelect(ranked: [PhotoScore]) -> [PhotoScore] {
        let cal = Calendar.current
        var chosen: [PhotoScore] = []
        var chosenIDs = Set<String>()

        func sameScene(_ s: PhotoScore) -> Bool {
            guard let fp = s.featurePrint, let d = s.date else { return false }
            for c in chosen {
                guard let cd = c.date, abs(cd.timeIntervalSince(d)) <= Self.sceneWindowHours * 3600,
                      let cfp = c.featurePrint else { continue }
                if VisionScorer.cosine(fp, cfp) >= Self.sceneSim { return true }
            }
            return false
        }

        @discardableResult
        func take(_ s: PhotoScore, checkScene: Bool = true) -> Bool {
            guard !chosenIDs.contains(s.id) else { return false }
            if checkScene && sameScene(s) { return false }
            chosen.append(s)
            chosenIDs.insert(s.id)
            return true
        }

        // week floors
        let weeks = Set(ranked.compactMap { $0.date.map { cal.component(.weekOfYear, from: $0) } })
        let floor = max(3, Self.shortlistTarget / max(1, weeks.count * 2))
        for w in weeks.sorted() {
            let pool = ranked.filter { $0.date.map { cal.component(.weekOfYear, from: $0) == w } ?? false }
            var taken = 0
            for p in pool where taken < floor {
                if take(p) { taken += 1 }
            }
        }
        // no-face quota
        let have = chosen.filter { $0.nFaces == 0 }.count
        if have < Self.noFaceQuota {
            var need = Self.noFaceQuota - have
            for p in ranked where p.nFaces == 0 && need > 0 {
                if take(p) { need -= 1 }
            }
        }
        // required-people guarantee: each starred person gets >=3 shortlist seats
        let required = PeopleStore.shared.requiredIDs
        for personID in required {
            var have = chosen.filter { $0.personIDs.contains(personID) }.count
            for p in ranked where have < 3 && p.personIDs.contains(personID) {
                if take(p) { have += 1 }
            }
        }
        // fill by rank, capping any single required person at 45% of the shortlist
        func overCap(_ p: PhotoScore) -> Bool {
            guard p.nFaces > 0, !required.isEmpty else { return false }
            for personID in required where p.personIDs.contains(personID) {
                let share = Float(chosen.filter { $0.personIDs.contains(personID) }.count) / Float(max(1, chosen.count))
                if share > 0.45 { return true }
            }
            return false
        }
        for p in ranked where chosen.count < Self.shortlistTarget {
            if !overCap(p) { take(p) }
        }
        // two-tier backfill (cap respected/scene relaxed, then everything relaxed)
        for p in ranked where chosen.count < Self.shortlistTarget { take(p) }
        for p in ranked where chosen.count < Self.shortlistTarget { take(p, checkScene: false) }
        return chosen
    }

    func loadThumbs(ids: [String], size: CGSize) async -> [String: UIImage] {
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

    private func record(_ name: String, since t0: Date, _ detail: String) {
        stageTimes.append(StageTime(name: name, seconds: Date().timeIntervalSince(t0), detail: detail))
        status = name + " done"
    }
}

enum PipelineError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}
