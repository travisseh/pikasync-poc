# PikaSync POC

**The question:** can an iOS app get ongoing access to new photos WITHOUT the user
opening it? This is the make-or-break for the Pikabook subscription-autopilot premise.

## What it does

On every wake (any trigger), it queries the photo library for photos created since
the last sync marker, then logs the event two ways:
- locally (visible in the app's Wake Log)
- as a push message to **https://ntfy.sh/pikasync-poc-trav-8347** (open that URL or
  install the ntfy app and subscribe — every background wake shows up there, so you
  can watch the experiment from any device with zero server setup)

## Experiment arms

1. **BGAppRefreshTask** — asks iOS for a wake every ~4h. iOS grants opportunistically
   based on usage patterns. This is the "true autonomy" arm.
2. **BGProcessingTask** — asks for a longer nightly task (network required). Second
   autonomy arm; iOS tends to run these when charging.
3. **Shortcuts automation** — set up once: Shortcuts app → Automation → Time of Day
   (daily 9pm) → Run Immediately → "Sync Photos Now". Runs without opening the app.
   This is the "guided setup" fallback arm.
4. *(Phase 2, not built)* **Silent push** — APNs `content-available` wake. Needs paid
   dev account + a sender. Add only if arms 1-2 disappoint.

## Setup (10 min)

1. `open PikaSync.xcodeproj`, select your team under Signing & Capabilities
2. Run on YOUR PHONE (not simulator — background behavior is meaningless there)
3. In the app: Request full access → Sync now (confirms the pipeline + beacon work)
4. Background the app. Create the Shortcuts automation (arm 3)
5. Use the phone normally for 2-3 weeks. Do NOT open the app daily — that would
   contaminate the experiment (iOS grants background time to apps you use)

## Success criteria (per arm, over 14 days)

- **Winning:** wakes on ≥10 of 14 days with new-photo counts captured
- **Viable-with-nudge:** wakes cluster around charging/overnight but land ≥5 of 7 days
- **Dead:** multi-day gaps with no wakes → autonomy requires the push→open→approve
  model (ChatBooks-style), which v1 was going to use anyway

Record: wake frequency per trigger type, longest gap, latency from photo-taken to
first wake that saw it (ntfy timestamps give you all of this).

## Android (deferred until iOS reads out)

WorkManager periodic job + READ_MEDIA_IMAGES is reliably wakeable — capability is a
non-question; the risk is Play Store review policy (core-functionality justification).
Build only if iOS proves out, or if the team wants parallel evidence for investors.
