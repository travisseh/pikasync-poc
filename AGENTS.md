# Agent notes — pikasync-poc

## Non-negotiables

- **Never commit `Sources/Secrets.swift`** (gitignored; `Secrets.example.swift.txt`
  is the committed placeholder). No API keys anywhere in tracked files — the
  Anthropic key lives only in the Vercel project's env vars.
- **Do not touch `SourcesBG/` or the installed PikaSyncBG app.** It runs a
  no-touch background-neglect experiment; modifying or reinstalling it
  invalidates days of data.
- Do not commit/push without explicit authorization from Travisse.

## Project mechanics

- Project file is generated: edit `project.yml`, then `xcodegen generate` after
  adding/removing files (a new file that "isn't in the project" means you skipped
  this).
- Three targets from one tree: `PikaSync` (`com.travisse.pikasync`, dev app),
  `PikabookTF` (`com.travisse.pikabook`, TestFlight — separate bundle so it
  coexists with the dev install; ASC app "Pikabook" 6804910168), and
  `PikaSyncBG` (`com.travisse.pikasync.bg`, sync-only experiment). Task IDs and
  the ntfy topic derive from the bundle ID.
- TestFlight ship: bump the PikabookTF version, archive, `-exportArchive`
  (method app-store-connect; cloud signing needs Xcode's signed-in account —
  the App Manager API key can't cloud-sign), upload with `xcrun altool
  --upload-app` (key `W9VQF245XW`, issuer `69a6de89-…a4d1`,
  `~/.appstoreconnect/private_keys/`), poll the ASC API until VALID. The
  Internal group has hasAccessToAllBuilds, so no per-build assignment.
- Build: `xcodebuild -project PikaSync.xcodeproj -scheme PikaSync -destination
  'generic/platform=iOS' -allowProvisioningUpdates build`

## Device tricks (WiFi, no cable, no Xcode UI)

- List devices: `xcrun devicectl list devices`
- Install: `xcrun devicectl device install app --device <udid> <path>.app`
- Launch (needs unlocked phone):
  `xcrun devicectl device process launch --device <udid> --terminate-existing com.travisse.pikasync`
- Pull/push app files without launching:
  `xcrun devicectl device copy from|to --device <udid> --domain-type appDataContainer --domain-identifier com.travisse.pikasync --source Documents/<file> --destination <path>`

## Where the state lives (app Documents/)

- `wake-log.json` — every wake/beacon event (also mirrored to
  `ntfy.sh/pikasync-poc-trav-8347`, ~12h retention; the file is the durable record)
- `last-run.json` — outcome of every pipeline run (status, error, stage timings),
  newest first — read this instead of asking for screenshots
- `command.json` — remote-control input, consumed on app activation
  (`{"action":"run"|"score"|"resetMonth"|"bgtick"|"setFlag","month":"yyyy-MM"}`;
  `setFlag` also takes `"flag"`/`"value"`, e.g. `experiment.skipProcessing`)
- `autobook-state.json` / `interactive-build.json` — persisted async-judge job
  state (background and interactive builds resume from these after suspension)
- `scores-yyyy-MM.json` — incremental per-month score store
- `people.json` — face clusters (names/starred/excluded)
- `runs.json` — saved books

## Judge server

`server/` deploys to Vercel (`pikasync-judge` project). Endpoints: sync
`POST /api/judge`; async `POST /api/judge/submit` → `{jobId}` (judges after the
response via `waitUntil`, result persisted to the Convex `judgeJobs` table,
writes gated by `JUDGE_JOB_SECRET`) and `GET /api/judge/result?jobId=…`.
Request bodies cap at 4.5MB — sheets render at 1x and the client steps JPEG
quality down to stay under it. Sonnet's internal reasoning counts against
`max_tokens`; keep the budget large (16k+) or replies can be all-reasoning with
no text.

## Analytics

PostHog via `Analytics.swift` (publishable key, fine to commit). Keep event
names in the shared cross-platform taxonomy (see README) — Android and web use
the same names so funnels merge. Never put photo content/filenames in
properties.
