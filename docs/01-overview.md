# 01 — Overview

## What we're building

ClipStack is a macOS clipboard manager: it silently records everything you copy
(text, links, images, files, colors), keeps it searchable forever, and lets you
paste any past item with a keyboard shortcut. Later: iOS companion app with
iCloud sync.

## Why

[Paste](https://apps.apple.com/us/app/paste-limitless-clipboard/id967805235)
does this very well but costs ~$30/year via subscription. Every core feature is
buildable with public Apple APIs — there is no secret sauce, just polish. We
build our own, free for personal use, with the option to ship it later.

## What Paste actually does (competitor analysis)

- **Unlimited clipboard history** — every copy is captured and stored locally.
- **Visual paste board** — a bottom-sheet overlay (summoned with `⌘⇧V`) showing
  history as large previews (cards), navigable by keyboard or mouse.
- **Instant search** — fuzzy search across text content, source app, and type.
- **Pinboards** — named collections where you pin frequently used snippets
  (email templates, addresses, code snippets).
- **Direct paste** — selecting an item pastes straight into the frontmost app,
  optionally as plain text.
- **Quick-paste hotkeys** — `⌘1…⌘9` paste the most recent items directly.
- **Rules / privacy** — exclude apps (password managers) from capture; ignores
  content flagged as transient/concealed (e.g., 1Password already marks its
  copies).
- **iCloud sync** — history and pinboards sync across Mac, iPhone, iPad.
- **Preview & edit** — view full content of an item, edit text before pasting.
- **Source app attribution** — shows which app each clip came from, with icon.
- **Data types** — rich text, plain text, URLs (with link previews), images,
  files, colors (rendered as swatches).

## Goals

1. **v0 (MVP):** history capture + overlay UI + search + paste. Daily-drivable.
2. **v1:** pinboards, rules, quick-paste hotkeys, previews — Paste parity on Mac.
3. **v2:** iCloud sync + iOS app (keyboard extension for pasting on iOS).

## Non-goals (for now)

- Windows/Linux versions.
- Team/shared clipboards.
- Monetization — build for ourselves first. If shipped later, prefer one-time
  purchase or freemium (RevenueCat experience already in hand).
