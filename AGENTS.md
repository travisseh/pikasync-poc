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
- Two targets from one tree: `PikaSync` (`com.travisse.pikasync`, full app) and
  `PikaSyncBG` (`com.travisse.pikasync.bg`, sync-only). Task IDs and the ntfy
  topic derive from the bundle ID.
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
  (`{"action":"run"|"score","month":"yyyy-MM"}`)
- `scores-yyyy-MM.json` — incremental per-month score store
- `people.json` — face clusters (names/starred/excluded)
- `runs.json` — saved books

## Judge server

`server/` deploys to Vercel (`pikasync-judge` project, prod URL
`https://pikasync-judge.vercel.app/api/judge`). Request bodies cap at 4.5MB —
sheets render at 1x and the client steps JPEG quality down to stay under it.
Sonnet's internal reasoning counts against `max_tokens`; keep the budget large
(16k+) or replies can be all-reasoning with no text.
