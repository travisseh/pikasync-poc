# PikaSync (iOS POC)

Pikabook proof of concept: **can a phone automatically turn a month of photos into a
printable photobook, in the background, for pennies?** This repo is the iOS half
(Android twin: [pikasync-android](https://github.com/travisseh/pikasync-android)).

Status: yes on quality (7 consecutive months of printable books from a real
library), yes on cost (~$0.05–0.15/book at POC, $0.01–0.05 with Haiku/Batch), and
yes-with-architecture on background (see wake strategy below).

## Architecture

Everything heavy runs **on-device**; only ~3 small contact-sheet JPEGs leave the
phone, judged by a tiny Vercel function that holds the Anthropic key
(`server/`, deployed at `https://pikasync-judge.vercel.app/api/judge`).

Pipeline stages (`Sources/Pipeline/`):

1. **Ingest** — PhotoKit month query; screenshots dropped via `PHAssetMediaSubtype`
2. **Vision scoring** — aesthetics + `isUtility`, face capture quality, landmarks,
   feature prints (`VisionScorer.swift`), checkpointed per-photo into a persistent
   score store (`IncrementalScorer.swift`, `Documents/scores-yyyy-MM.json`)
3. **Face identity** — ArcFace embeddings via a Core ML port (`FaceEmbedder.swift`,
   `Sources/Models/`); running-mean person clusters persist in
   `Documents/people.json`, editable in the People tab (name / star = required /
   exclude), applied to every generation
4. **Burst dedup** — 90s window + feature-print cosine ≥ 0.92
5. **Coverage shortlist** — week floors, no-face quota, starred-person guarantee +
   45% cap, excluded-person and stranger drops
6. **Scene collapse** — union-find scene clustering on the shortlist (cosine ≥ 0.82
   within 6h), max 3 representatives per cluster (kills near-duplicate pages)
7. **Contact sheets** — 4×4 labeled grids at 1x scale (`ContactSheetRenderer.swift`)
8. **Judge** — server-side claude-sonnet-5 picks and orders the book; book size is
   `max(4, min(poolScaled, 2×sessions, sceneClusters))`
9. **Scene check** — deterministic post-judge duplicate detection; one corrective
   retry at ≥2 residual pairs (1 pair tolerated: major events earn a second page)

Books persist in `Documents/runs.json` (Books tab, swipe or trash-icon to delete).

## Background strategy (the hard-won part)

- **bg_refresh** (~30s budget): proven to fire 1–3×/day for 6+ days on an unused
  app. The book job is chunked to fit it — each wake scores ~15s of photos;
  month-close needs only shortlist + sheets + one server call (`AutoBook.tick`).
- **bg_processing** (minutes budget): empirically starved — zero grants in 6 days
  on an unused app. Still registered with `requiresExternalPower = true` as a
  bonus path.
- **Shortcuts automation** (daily time trigger) as a guided-setup arm, plus a
  4-day dead-man local notification that only fires if wakes stop.
- Every wake beacons to `ntfy.sh/pikasync-poc-trav-8347` and appends to
  `Documents/wake-log.json`.

`PikaSyncBG` is a second, sync-only target (`SourcesBG/`) running a no-touch
neglect experiment. **Do not modify or reinstall it.**

## Build & run

```bash
brew install xcodegen
xcodegen generate            # re-run after adding/removing files
open PikaSync.xcodeproj      # select your team, run the PikaSync scheme on a real phone
```

Create `Sources/Secrets.swift` from `Secrets.example.swift.txt` (gitignored; only
needed if you re-enable any direct-API path — judging normally goes through the
server, no key on device).

Server deploy: `cd server && vercel --prod` with `ANTHROPIC_API_KEY` set as a
Vercel env var.

## Remote control & observability (no hands on the phone)

- Trigger a run: write `{"action":"run","month":"2026-05"}` (or `"score"` to fill
  the score store only) to `Documents/command.json` via
  `xcrun devicectl device copy to --domain-type appDataContainer
  --domain-identifier com.travisse.pikasync ...`, then
  `xcrun devicectl device process launch com.travisse.pikasync` (device must be
  unlocked). The app consumes the command on becoming active.
- Every run (manual/remote/bg) appends to `Documents/last-run.json` — status,
  error, per-stage timings — pullable with `devicectl device copy from`.

## License note

The bundled face model derives from InsightFace weights (non-commercial research
license). POC only — production ships AuraFace-v1 (commercial-friendly) or a
licensed model.
