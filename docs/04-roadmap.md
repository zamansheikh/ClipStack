# 04 — Roadmap

Phases are ordered so the app becomes *daily-usable as early as possible* —
dogfooding it yourself is the fastest way to find what matters.

## Phase 0 — Skeleton (≈ 1–2 days)

- [x] Xcode project: SwiftUI app, `LSUIElement`, menu bar item with basic menu
      (Open History, Settings, Quit). *(XcodeGen — edit `project.yml`.)*
- [x] Add GRDB + KeyboardShortcuts via Swift Package Manager.
- [x] Overlay panel toggled by `⌘⇧V` (non-activating `NSPanel` implemented —
      **manually verify it doesn't steal focus** against Safari/Xcode/Electron).

**Exit criteria:** hotkey shows/hides a floating panel without stealing focus.

## Phase 1 — MVP (≈ 1–2 weeks)

- [x] ClipboardWatcher + IngestPipeline (text, URLs, images, files) —
      capture/dedupe/URL-detection verified end-to-end via sqlite.
- [x] GRDB store, dedupe, blob-on-disk.
- [x] Overlay: card row, keyboard navigation, type-to-search.
- [x] PasteService: direct paste, paste-as-plain-text — **needs manual
      verification** (requires Accessibility grant + real target apps).
- [x] Accessibility onboarding flow; launch at login.
- [x] Settings window: history limit, clear history, hotkey remap.

**Exit criteria: you stop using ⌘V's amnesia — ClipStack is your daily driver.**

## Phase 2 — Paste parity (≈ 2–3 weeks)

- [ ] Pinboards (tabs, pin/unpin, reorder).
- [ ] Rules: per-app exclusion.
- [ ] Quick paste `⌘1…⌘9` in overlay.
- [ ] `Space` preview + edit-before-paste.
- [ ] FTS5 full-text search + type filter chips.
- [ ] Drag-out of overlay; multi-select paste stack.
- [ ] App icon, polish pass, Developer ID signing + notarization.

**Exit criteria:** a Paste user switching over misses nothing important on Mac.

## Phase 3 — Sync & iOS (later)

- [ ] CloudKit sync (history + pinboards, image size cap).
- [ ] iOS app: browse/search, keyboard extension, share extension.
- [ ] App Store sandbox audit if distributing there.

## Decisions already made

| Decision | Choice | Why |
|----------|--------|-----|
| Stack | Native Swift/SwiftUI | App is mostly OS integration (see 03) |
| Storage | GRDB/SQLite | Mature, FTS5, full control vs SwiftData |
| Distribution first | Direct download | No sandbox friction while iterating |
| Monetization | None for now | Building for ourselves; decide at Phase 2 exit |

## Open questions (decide when we get there)

- Final app name + icon.
- Sandbox + App Store vs direct-only.
- Whether iOS is worth a keyboard-extension's review pain.
