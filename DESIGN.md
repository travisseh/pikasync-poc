# Pikabook Design Language

Shared visual spec for the iOS (SwiftUI) and Android (Compose) apps. Airbnb-family
feel: white, image-forward, soft depth, friendly type, sheets over alerts.

## Tokens

| Token | Value | Use |
|---|---|---|
| `bg` | `#FFFFFF` | screen background |
| `bgSoft` | `#F7F7F7` | inset sections, sheet grabber areas, input fills |
| `ink` | `#222222` | primary text |
| `inkSecondary` | `#717171` | secondary text, captions |
| `hairline` | `#EBEBEB` | dividers, card strokes (1pt) |
| `accent` | `#FF385C` | the one warm accent: primary buttons, active states, stars |
| `accentPress` | `#E31C5F` | pressed accent |
| `scrim` | black 0% → 55% vertical gradient | text-over-photo legibility |

- **Radii**: cards & photos 16, buttons/pills 24 (full pill), sheets 20 top corners, chips 12.
- **Shadows** (layered, soft): `black 8% blur 24 y8` + `black 4% blur 4 y1`. Never hard borders for elevation; hairline stroke only on white-on-white cards.
- **Type**: system font. Screen titles 28-32 bold ("Your books"). Card overlay titles 22 semibold white. Body 16. Captions 13 `inkSecondary`. Generous line spacing.
- **Spacing**: screen gutters 20, card gap 20, section gap 28. Whitespace is the layout.

## Component rules

- **Photo cards**: the photo IS the card. Edge-to-edge image, radius 16, scrim gradient bottom third, title + subtitle overlaid bottom-left in white. Soft shadow. Press = scale 0.97 with spring (response 0.3, damping 0.7).
- **Primary button**: accent pill, white 16pt semibold text, height 48-52, full-width in context. Secondary = white pill, hairline stroke, ink text.
- **Bottom sheets, not alerts**: actions (share/feedback/delete), forms, and confirmations present as sheets with 20pt top radius, grabber, medium detent. Destructive confirm = sheet with a red full-width pill.
- **Reaction pills**: big tappable emoji chips (56pt), selected = accent tint background 12% + accent stroke.
- **Chips over photos**: small translucent white capsules (material blur) with icon+label, bottom overlay.
- **Animations**: springs only (response 0.3-0.4, damping 0.7-0.8). Content transitions fade+slide 8pt. No linear/ease-in-out for interactive elements.
- **Empty states**: friendly headline + one-line body + primary pill. Never bare gray text.
- **Dev surfaces** (pipeline/sync screens): same palette, plain lists are fine — light touch.

## Navigation & create flow (v2)

- **Bottom nav**: NORMAL docked opaque bar (white, hairline top edge, accent
  selected state). No floating/liquid-glass bar. Springy screen transitions
  stay where cheap.
- **FAB**: 56pt accent circle with a white plus, bottom-right, floating above
  the nav bar (20 right / 16 bottom inside the content area). This is the only
  create entry point — no "Create a book" pill in the list.
- **Create sheet**: FAB opens a bottom sheet titled "Create Photobook" — a
  2-column grid of the last 12 months as selectable chips (accent tint 10% +
  accent stroke when selected) and a full-width accent "Create" pill.
- **In-list loading entry**: Create inserts a card at the TOP of the Books
  list: soft bgSoft card (~148pt) with a moving shimmer highlight, month label
  and the live stage text. Tap → bottom sheet with the live dev stage list.
  Failure keeps the card ("Couldn't make this book — tap for details") with a
  Try again + Remove in its sheet. Success: the card is replaced by the normal
  cover card.
- **Pipeline details**: a finished book's "…" sheet has "Pipeline details" —
  the persisted stage list (name, detail, seconds, total, judge usage).
- **Auto-share**: every book uploads to the share backend automatically right
  after it's created (interactive and background); failures retry via an
  app-open sweep. Feedback is therefore never gated on a manual share.

## Book viewer spreads (v2)

- All photos display as SQUARES (top-anchored center crop so faces survive).
- Unit 1 is the **title page**: one square + title + month, like a printed
  cover. Every following unit is a **spread**: TWO squares side by side on a
  white page card (10 gap, 14 padding, radius 16, soft shadow). An odd final
  page gets a blank bgSoft facing square.
- Tap any square → the photo FULL SIZE, uncropped, on white, with an X close
  and a "Feedback on this photo" accent pill (per-photo feedback).
- No page numbers anywhere ("N of M" is gone). Page dots only.

## Naming

iOS: `Pika.bg`, `Pika.ink`, `Pika.accent`… in `Sources/Theme.swift`.
Android: `PikaColor.Bg`… in `ui/Theme.kt`. Keep names aligned.
