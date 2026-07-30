# 02 — Feature Specification

Feature-by-feature spec, grouped by release phase. ✅ = must have, 🔶 = nice to have.

## Phase 1 — MVP

### ✅ Clipboard capture (the core loop)
- Poll `NSPasteboard.general.changeCount` on a timer (~0.3 s). macOS has no
  public pasteboard-change notification; polling is what every clipboard
  manager does. Negligible CPU when nothing changes.
- On change, read available types in priority order:
  file URLs → images → RTF/HTML → plain text → colors.
- Store: content, type, source app (frontmost app at copy time — bundle ID,
  name, icon), timestamp, character/byte count.
- Deduplicate: re-copying an existing item moves it to the top instead of
  creating a duplicate.
- **Respect `org.nspasteboard.ConcealedType` and `TransientType`** — never
  store these (password managers mark their copies this way). Non-negotiable.

### ✅ History overlay UI
- Menu bar app (no Dock icon by default) — `MenuBarExtra` + a custom
  borderless `NSPanel` for the overlay.
- Global hotkey `⌘⇧V` toggles a bottom-anchored panel over the current screen,
  Paste-style: horizontal row of preview cards, newest first.
- Card shows: type icon/thumbnail, content preview, source app icon, relative
  time ("2m ago").
- Keyboard-first: arrow keys navigate, `Return` pastes, `Esc` dismisses,
  typing starts search immediately.
- Overlay must not steal focus from the target app (use a non-activating
  panel) so paste lands in the right place.

### ✅ Search
- Type-to-filter in the overlay; instant, fuzzy-ish (prefix + substring first;
  full FTS later).
- Filter chips by type: Text / Links / Images / Files.

### ✅ Paste actions
- `Return` — paste into frontmost app: put item on pasteboard, then synthesize
  `⌘V` via `CGEvent` (requires Accessibility permission).
- `⇧Return` or `⌥Return` — paste as plain text.
- `⌘C` on a selected card — just copy, don't paste.
- Drag a card out of the overlay into any app.

### ✅ Storage & retention
- Local database (SQLite via GRDB). Images/large blobs on disk, referenced by
  the DB row; text inline.
- Settings: history limit (unlimited / N items / N days), "Clear history".

### ✅ Onboarding & permissions
- First-run flow requesting Accessibility permission (needed for direct
  paste), with a clear explanation and a "skip — copy-only mode" path.
- Launch at login (`SMAppService`).

## Phase 2 — Paste parity

### ✅ Pinboards
- Named collections shown as tabs in the overlay ("History" + user pinboards).
- Pin any history item; pinned items never expire. Reorder by drag.

### ✅ Rules (privacy)
- Per-app exclusion list ("never capture from these apps").
- Optional: pattern-based ignore (e.g., anything matching a credit-card regex).

### ✅ Quick paste
- `⌘1…⌘9` inside the overlay pastes item 1–9.
- Optional global quick-paste layer like Paste's.

### ✅ Item preview & edit
- `Space` on a card opens a large preview (full text, full-size image, link
  preview with title/favicon).
- Edit text items in place before pasting.

### 🔶 Polish
- Paste-stack: select multiple items, paste sequentially.
- Ignore-once mode (pause capture for 5 minutes).
- Sound/haptics options, light/dark themes.
- Full-text search via SQLite FTS5.

## Phase 3 — Sync & iOS

### ✅ iCloud sync
- CloudKit private database; sync history + pinboards. Conflict policy:
  last-writer-wins per item (items are mostly immutable — simple).
- Size cap for synced images; large blobs stay local-only or use CKAsset.

### ✅ iOS companion
- SwiftUI app: browse/search history, pinboards.
- Custom keyboard extension for pasting any item anywhere (this is how Paste
  does iOS pasting).
- Share extension to add items.

## Explicitly out of scope (v1)

- Windows/Linux, browser extensions, team sharing, OCR on images.
