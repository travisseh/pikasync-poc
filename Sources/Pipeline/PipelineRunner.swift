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

    /// Who kicked off this run — "manual", "remote", or "bg" — recorded in last-run.json.
    var trigger = "manual"

    /// Everything between "month is fully scored" and "judge": gate, dedup,
    /// shortlist, scene collapse, sheets, and book sizing. Shared by the
    /// interactive run (which judges synchronously) and the background path
    /// (which submits an async job and collects it on a later wake).
    struct Prepared {
        let month: Date
        let monthName: String
        let chosen: [PhotoScore]   // chronological, shortlistIndex == position
        let sheets: [UIImage]
        let bookCount: Int
        let clusterCount: Int
    }

    func run(month: Date) async {
        running = true
        errorText = nil
        book = nil
        sheets = []
        stageTimes = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        let monthKey = df.string(from: month)
        defer {
            running = false
            RunStatusLog.write(month: monthKey, status: status, error: errorText,
                               stages: stageTimes.map { "\($0.name): \($0.detail) (\(String(format: "%.1f", $0.seconds))s)" },
                               trigger: trigger)
        }

        do {
            let prepared = try await prepare(month: month)
            let monthName = prepared.monthName
            let chosen = prepared.chosen
            let bookCount = prepared.bookCount

            // Stage 6: LLM judge (synchronous endpoint for interactive runs)
            var t0 = Date()
            status = "judging (claude-sonnet-5)"
            var result = try await JudgeClient.judge(sheets: sheets, monthLabel: monthName, count: bookCount, maxIndex: chosen.count - 1)

            // Deterministic same-scene check on the judge's picks: prompt rules
            // bend under pool pressure, feature-print math doesn't. One residual
            // pair is tolerated (a major event legitimately carries two pages);
            // retry only at >=2.
            let violations = sceneViolations(result.book, chosen: chosen)
            if violations.count >= 2 {
                let detail = correctionText(violations)
                status = "judge re-pick (\(violations.count) same-scene pairs)"
                result = try await JudgeClient.judge(sheets: sheets, monthLabel: monthName, count: bookCount, maxIndex: chosen.count - 1, correction: detail)
                let remaining = sceneViolations(result.book, chosen: chosen)
                record("scene re-pick", since: t0, remaining.count <= 1 ? "clean after retry (\(remaining.count) residual)" : "\(remaining.count) pairs still similar (accepted)")
            } else if violations.count == 1 {
                record("scene check", since: t0, "1 residual pair (tolerated — likely major event)")
            }
            record("LLM judge", since: t0, result.usageSummary)
            t0 = Date()
            _ = await saveBook(result: result, chosen: chosen, monthName: monthName, share: true)
        } catch {
            errorText = "\(error)"
            status = "failed"
        }
    }

    /// Stages 1-5 + sizing. Throws on permission / thin-month problems.
    func prepare(month: Date) async throws -> Prepared {
        var t0 = Date()
        status = "scoring…"
        let chunk = await IncrementalScorer.scoreChunk(month: month, budget: nil) { done, total in
            self.status = "scoring \(done)/\(total)"
            self.progress = Double(done) / Double(max(1, total))
        }
        guard chunk.total >= 0 else { throw PipelineError.message("no photo permission") }
        guard chunk.total >= 8 else {
            throw PipelineError.message("Only \(chunk.total) photos in that month — pick a busier one")
        }
        let scores = IncrementalScorer.loadScores(month: month)
        record("scoring", since: t0, "\(chunk.total) in month, \(chunk.newlyScored) newly scored, \(chunk.total - chunk.newlyScored) from store")
        return try await prepare(month: month, scores: scores)
    }

    /// Stages 3-5 + sizing from an already-loaded score set (background path
    /// has scored the month across earlier wakes).
    func prepare(month: Date, scores: [PhotoScore]) async throws -> Prepared {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!

        // Stage 3: quality gate + burst dedup (+ excluded-people drop)
        var t0 = Date()
        let people = PeopleStore.shared
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
        // Pre-judge scene collapse (proven in eval round 3): the backfill
        // tiers can let one scene flood the shortlist, and the post-judge
        // repair can then only swap within that flood. Cap representatives
        // per scene cluster BEFORE the judge ever sees them.
        let clusters = sceneClusters(chosen)
        let preCollapse = chosen.count
        var keep = Set<Int>()
        for members in clusters {
            for i in members.sorted(by: { chosen[$0].finalScore > chosen[$1].finalScore }).prefix(3) {
                keep.insert(i)
            }
        }
        chosen = keep.sorted().map { chosen[$0] }
        chosen.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        for i in chosen.indices { chosen[i].shortlistIndex = i }
        shortlist = chosen
        let noFace = chosen.filter { $0.nFaces == 0 }.count
        record("shortlist", since: t0, "\(chosen.count) chosen (\(preCollapse - chosen.count) scene-collapsed, \(clusters.count) scenes), \(noFace) no-face")
        guard chosen.count >= 4 else { throw PipelineError.message("Only \(chosen.count) usable photos after gating") }

        // Stage 5: contact sheets
        t0 = Date()
        status = "rendering sheets"
        let images = await loadThumbs(ids: chosen.map(\.id), size: CGSize(width: 420, height: 420))
        sheets = ContactSheetRenderer.render(scores: chosen, thumbs: images)
        record("contact sheets", since: t0, "\(sheets.count) sheets of \(chosen.count) photos")

        let monthName = DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .none)
        // Never ask for a book the pool can't support: judge needs real
        // choice (~2.5x), thin-variety months must shrink instead of
        // duplicating, and a book can't have more pages than distinct
        // scenes (all three caps proven necessary in eval).
        let poolScaled = min(Self.bookSize, max(8, chosen.count * 5 / 12))
        let sessions = sessionCount(chosen)
        let bookCount = max(4, min(poolScaled, max(6, 2 * sessions), clusters.count))
        return Prepared(month: month, monthName: monthName, chosen: chosen, sheets: sheets,
                        bookCount: bookCount, clusterCount: clusters.count)
    }

    /// Rebuild a shortlist from persisted asset IDs (background collect step):
    /// same photos, same order, shortlistIndex == position, feature prints
    /// restored from the score store for the scene check.
    static func chosen(fromIDs ids: [String], month: Date) -> [PhotoScore] {
        let byID = Dictionary(IncrementalScorer.loadScores(month: month).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PhotoScore] = []
        for (i, id) in ids.enumerated() {
            var s = byID[id] ?? PhotoScore(id: id, date: nil)
            s.shortlistIndex = i
            out.append(s)
        }
        return out
    }

    func correctionText(_ violations: [(Int, Int)]) -> String {
        violations.map { "picks \($0.0) and \($0.1) are the same scene — replace one of each pair" }.joined(separator: "; ")
    }

    /// Persist the judged book as a SavedRun (+ optional auto-share). Returns
    /// the saved run, or nil if the cover couldn't be mapped.
    @discardableResult
    func saveBook(result: JudgeClient.JudgeOutput, chosen: [PhotoScore], monthName: String, share: Bool) async -> SavedRun? {
        judgeInfo = result.usageSummary
        book = result.book
        status = "done — \(result.book.selections.count)-photo book ready"

        let byIndex = Dictionary(uniqueKeysWithValues: chosen.compactMap { s in s.shortlistIndex.map { ($0, s.id) } })
        let sels = result.book.selections.compactMap { sel in
            byIndex[sel.index].map { SavedRun.Selection(assetID: $0, page: sel.page) }
        }
        guard let coverID = byIndex[result.book.cover_index] else { return nil }
        let thumb = await loadThumbs(ids: [coverID], size: CGSize(width: 600, height: 600))[coverID]
        let saved = SavedRun(
            id: UUID(), createdAt: Date(), monthLabel: monthName,
            title: result.book.title, coverAssetID: coverID, selections: sels,
            totalSeconds: stageTimes.reduce(0) { $0 + $1.seconds },
            judgeInfo: result.usageSummary,
            coverThumbJPEG: thumb?.jpegData(compressionQuality: 0.8),
            stages: stageTimes.map { .init(name: $0.name, detail: $0.detail, seconds: $0.seconds) })
        RunStore.shared.add(saved)

        if share {
            // Auto-share: every book becomes shareable/feedback-able the
            // moment it exists. Best-effort — a failure here never fails
            // the run; the app-open sweep retries any unshared book.
            status = "sharing your book…"
            _ = await ShareClient.ensureShared(runID: saved.id) { [weak self] in self?.status = $0 }
            status = "done — \(result.book.selections.count)-photo book ready"
        }
        return saved
    }

    /// Union-find scene clusters over the shortlist: same cluster when
    /// feature-print cosine >= sceneSim within the scene time window.
    private func sceneClusters(_ photos: [PhotoScore]) -> [[Int]] {
        var parent = Array(0..<photos.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<photos.count {
            guard let fi = photos[i].featurePrint, let di = photos[i].date else { continue }
            for j in (i + 1)..<photos.count {
                guard let fj = photos[j].featurePrint, let dj = photos[j].date,
                      abs(di.timeIntervalSince(dj)) <= Self.sceneWindowHours * 3600,
                      VisionScorer.cosine(fi, fj) >= Self.sceneSim else { continue }
                parent[find(j)] = find(i)
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in 0..<photos.count { clusters[find(i), default: []].append(i) }
        return Array(clusters.values)
    }

    /// Distinct sessions: 3h time-gap clusters, merged when any cross-session
    /// pair is scene-similar (a trip revisited across the day is one session).
    private func sessionCount(_ photos: [PhotoScore]) -> Int {
        let dated = photos.filter { $0.date != nil }.sorted { $0.date! < $1.date! }
        guard !dated.isEmpty else { return 0 }
        var sessions: [[PhotoScore]] = []
        var lastDate: Date? = nil
        for p in dated {
            if let last = lastDate, p.date!.timeIntervalSince(last) <= 3 * 3600 {
                sessions[sessions.count - 1].append(p)
            } else {
                sessions.append([p])
            }
            lastDate = p.date
        }
        var parent = Array(0..<sessions.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<sessions.count {
            for j in (i + 1)..<sessions.count where find(i) != find(j) {
                let hit = sessions[i].contains { a in
                    guard let fa = a.featurePrint else { return false }
                    return sessions[j].contains { b in
                        guard let fb = b.featurePrint else { return false }
                        return VisionScorer.cosine(fa, fb) >= Self.sceneSim
                    }
                }
                if hit { parent[find(j)] = find(i) }
            }
        }
        return Set((0..<sessions.count).map(find)).count
    }

    /// Pairs of picked shortlist indexes that are the same scene by feature-print
    /// similarity within the scene window.
    func sceneViolations(_ book: BookResult, chosen: [PhotoScore]) -> [(Int, Int)] {
        let byIdx = Dictionary(uniqueKeysWithValues: chosen.compactMap { s in s.shortlistIndex.map { ($0, s) } })
        let picks = book.selections.map(\.index)
        var out: [(Int, Int)] = []
        for i in 0..<picks.count {
            for j in (i + 1)..<picks.count {
                guard let a = byIdx[picks[i]], let b = byIdx[picks[j]],
                      let fa = a.featurePrint, let fb = b.featurePrint,
                      let da = a.date, let db = b.date,
                      abs(da.timeIntervalSince(db)) <= Self.sceneWindowHours * 3600,
                      VisionScorer.cosine(fa, fb) >= Self.sceneSim else { continue }
                out.append((picks[i], picks[j]))
            }
        }
        return out
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

        // When the book is "about" starred people, face-photos that contain
        // detected people but NONE of the starred ones are strangers — drop.
        // (Photos with no eligible faces still qualify as texture shots.)
        let requiredSet = PeopleStore.shared.requiredIDs
        let ranked = requiredSet.isEmpty ? ranked : ranked.filter {
            $0.personIDs.isEmpty || !$0.personIDs.isDisjoint(with: requiredSet)
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
