# PikaSync (iOS POC)

Pikabook proof of concept: **can a phone automatically turn a month of photos into a
printable photobook, in the background, for pennies?** This repo is the iOS half
(Android twin: [pikasync-android](https://github.com/travisseh/pikasync-android)).

Status: yes on quality (7 consecutive months of printable books from a real
library), yes on cost (~$0.05–0.15/book at POC, $0.01–0.05 with Haiku/Batch), and
yes on background (books built by genuine iOS-initiated wakes on Aug 25/26/27 with
zero interaction — see wake strategy below).

## Architecture

Everything heavy runs **on-device**; only ~3 small contact-sheet JPEGs leave the
phone, judged by a Vercel function that holds the Anthropic key (`server/`,
deployed at `https://pikasync-judge.vercel.app`). Judging is **async**:
`POST /api/judge/submit` returns a jobId in ~2s (the server judges after
responding via `waitUntil`, persisting the result in Convex), and
`GET /api/judge/result?jobId=…` collects it — so no phone-side step ever has to
outlive a 30s background window or a screen lock. The synchronous
`POST /api/judge` remains for tooling.

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
8. **Judge** — server-side claude-sonnet-5 picks and orders the book (no captions);
   book size is `max(4, min(poolScaled, 2×sessions, sceneClusters))`
9. **Scene check** — deterministic post-judge duplicate detection; one corrective
   retry at ≥2 residual pairs (1 pair tolerated: major events earn a second page)

After a book saves, it **auto-shares silently**: the ~10–17 chosen pages upload
concurrently (5 at a time, 1600px derivatives, no full-res iCloud fetches) to the
[pikabook-share](https://github.com/travisseh/pikabook-share) backend, and the
share/feedback link is cached on the book. The only visible state is a spinner on
the share/feedback button if tapped before the link is ready.

## UX

Airbnb-style design system (`DESIGN.md`, shared with Android): white,
image-forward hero cards, coral accent, bottom sheets, spring motion. First-run
onboarding: welcome → permission priming → scan of the 200 most recent photos
(which also pre-pays pipeline scoring) → top-10 most-photographed grid with the
top 3 pre-selected as the "every photo includes at least one of them" set →
explicit "Make my first book" step. Book viewer renders square spreads (title
page, then two-up); tap any square for the full photo + per-photo feedback.
Interactive builds keep the screen awake, run the judge as an async job persisted
to disk, and resume after suspension or app kill.

## Background strategy (the hard-won part)

`AutoBook.tick` is a resumable state machine sized for the ~30s bg_refresh
budget: each wake does ONE step — score a ~15s chunk of last month, or
shortlist+sheets+**submit** the async judge job, or **collect** the result
(scene check, optional one corrective resubmit, save + notify). Generous wakes
(bg_processing / remote) run submit→collect in one pass.

Measured findings (Aug 2026, two apps incl. a no-touch control):

- **Some background wake arrives every day**, but iOS chooses the type and that
  choice shifts: early week favored bg_refresh (1–3×/day), later week
  bg_processing daily (with `requiresExternalPower = true`, phone charging).
  The state machine is deliberately agnostic to which arm fires.
- Install churn / force-launching suppresses wakes (a dev-only artifact);
  a deliberately ignored app kept waking daily.
- Shortcuts automation (daily time trigger) exists as a guided-setup arm, plus a
  4-day dead-man local notification that only fires if wakes stop.
- Every wake beacons to `ntfy.sh/pikasync-poc-trav-8347` and appends to
  `Documents/wake-log.json`.

`PikaSyncBG` is a second, sync-only target (`SourcesBG/`) running a no-touch
neglect experiment. **Do not modify or reinstall it.**

## Targets & distribution

Three targets from one tree: `PikaSync` (dev, `com.travisse.pikasync`),
`PikabookTF` (TestFlight, `com.travisse.pikabook` — separate bundle so dev and
TestFlight installs coexist), `PikaSyncBG` (experiment). TestFlight app record:
"Pikabook" (ASC 6804910168); Android testers get Firebase App Distribution.

## Analytics

PostHog (project `pikabook`, Denada org, US cloud; publishable key
`phc_omBAXECCW6N5Cr6YZovQYJpC6qNt4oCQ9tvkdiX9PsuR` in `Analytics.swift`).
Shared cross-platform taxonomy: onboarding steps, `book_stage` per pipeline
stage, `judge_submitted/collected` (cost), `share_upload_*`, `feedback_posted`,
`book_viewed/deleted`, `run_failed`. "Onboarding" funnel insight lives in the
PostHog project.

## Build & run

```bash
brew install xcodegen
xcodegen generate            # re-run after adding/removing files
open PikaSync.xcodeproj      # select your team, run the PikaSync scheme on a real phone
```

`Sources/Secrets.swift` (from `Secrets.example.swift.txt`, gitignored) is only
needed if you re-enable a direct-API path — judging goes through the server, no
key on device.

Server deploy: `cd server && vercel --prod` with `ANTHROPIC_API_KEY` (and
`JUDGE_JOB_SECRET`, `CONVEX_SITE_URL` for the async job store) set as Vercel env
vars.

## Remote control & observability (no hands on the phone)

- Write `Documents/command.json` via `xcrun devicectl device copy to
  --domain-type appDataContainer --domain-identifier com.travisse.pikasync ...`,
  then `xcrun devicectl device process launch com.travisse.pikasync` (unlocked
  phone). Actions: `run` (full book), `score` (fill score store),
  `resetMonth` (clear the monthly auto-book marker), `bgtick` (run one AutoBook
  step), `setFlag` (e.g. `experiment.skipProcessing`).
- Every run (manual/remote/bg) appends to `Documents/last-run.json` — status,
  error, per-stage timings — pullable with `devicectl device copy from`.

## Service map

- **Vercel**: `pikasync-judge` (this repo's `server/`), `pikabook-share`
  (share viewer), `pikabook-site` (marketing + `/try` web funnel)
- **Convex** `silent-marmot-268`: `books`/`pages`/`feedback` (sharing),
  `judgeJobs` (async judge store), `webJobs` (web funnel queue)
- **Railway**: `pikabook-worker` (Python pipeline for web uploads, in
  pikabook-site `worker/`)
- **PostHog**: project `pikabook` (Denada org)

## License note

The bundled face model derives from InsightFace weights (non-commercial research
license). POC only — production ships AuraFace-v1 (commercial-friendly) or a
licensed model.
