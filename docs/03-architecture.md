# 03 — Architecture

## Stack decision

**Native Swift + SwiftUI (macOS 14+), AppKit where SwiftUI falls short.**

Why not Flutter (even though it's the familiar stack): a clipboard manager is
~80% OS integration — `NSPasteboard`, `CGEvent` keystroke synthesis,
non-activating `NSPanel`, Accessibility permission, menu bar lifecycle,
`SMAppService`, CloudKit. In Flutter every one of those becomes a platform
channel into Swift anyway; the Dart layer would only own the UI while fighting
the windowing model (borderless non-activating overlay panels are painful in
Flutter macOS). Going native also makes the future iOS app + iCloud sync
first-class. This is a great project to learn Swift on — the UI is small.

| Concern | Choice |
|---------|--------|
| Language / UI | Swift 5.10+, SwiftUI (AppKit interop for panels) |
| Min target | macOS 14 (Sonoma) |
| Persistence | SQLite via [GRDB](https://github.com/groue/GRDB.swift) (+ FTS5 later) |
| Global hotkeys | [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (sandbox-friendly, App Store safe) |
| Launch at login | `SMAppService.mainApp` |
| Sync (v2) | CloudKit private DB |
| Distribution | Direct (Developer ID + notarization) first; App Store later |

**Sandbox note:** Reading the general pasteboard is allowed in the sandbox, but
*direct paste* (synthesizing `⌘V`) needs Accessibility permission, which App
Store review does accept for this app category (Paste itself is sandboxed and
on the App Store). Start unsandboxed for development simplicity; revisit for
App Store release.

## Process model

Single menu-bar app (`LSUIElement = YES`, no Dock icon):

```
┌────────────────────────────────────────────────┐
│ ClipStack.app (menu bar)                       │
│                                                │
│  ClipboardWatcher ──▶ IngestPipeline ──▶ Store │
│   (poll changeCount)   (classify, dedupe,      │
│                         source app, thumbs)    │
│                                    │           │
│  HotkeyManager ──▶ OverlayPanel ◀──┘ (queries) │
│   (⌘⇧V)             (NSPanel + SwiftUI)        │
│                        │                       │
│                        ▼                       │
│                   PasteService                 │
│            (set pasteboard + CGEvent ⌘V)       │
└────────────────────────────────────────────────┘
```

### Key components

- **ClipboardWatcher** — `Timer` (0.3 s) checking `changeCount`. Skips items
  marked `org.nspasteboard.ConcealedType` / `TransientType` / auto-generated.
- **IngestPipeline** — decides the canonical type (fileURL > image > rtf >
  string > color), captures `NSWorkspace.shared.frontmostApplication` as
  source, generates thumbnails off-main-actor, dedupes by content hash.
- **Store** — GRDB `DatabaseQueue`; blobs ≥ ~100 KB go to
  `Application Support/ClipStack/blobs/<sha256>`, row keeps the path.
- **OverlayPanel** — custom `NSPanel` subclass: `.nonactivatingPanel`,
  borderless, floating level, anchored to bottom of the screen with the mouse.
  Hosts SwiftUI via `NSHostingView`. Never activates the app → frontmost app
  keeps focus → paste goes to the right place.
- **PasteService** — writes the chosen representation to the pasteboard, then
  posts `⌘V` key-down/up via `CGEvent` (guarded by `AXIsProcessTrusted()`).
  Marks its own writes with a custom pasteboard type so the watcher can
  re-record moved-to-top items without loops.

## Data model (v1)

```sql
CREATE TABLE clip (
  id            TEXT PRIMARY KEY,          -- UUID
  kind          TEXT NOT NULL,             -- text|rtf|url|image|file|color
  text_content  TEXT,                      -- plain-text form (also for search)
  data_path     TEXT,                      -- blob file, if any
  preview_path  TEXT,                      -- thumbnail, if any
  content_hash  TEXT NOT NULL,             -- dedupe key
  source_bundle TEXT,                      -- e.g. com.apple.Safari
  source_name   TEXT,
  byte_size     INTEGER NOT NULL,
  created_at    DATETIME NOT NULL,
  last_used_at  DATETIME NOT NULL,         -- copy again → bump this
  pinboard_id   TEXT REFERENCES pinboard(id)  -- NULL = plain history
);
CREATE UNIQUE INDEX clip_hash ON clip(content_hash, pinboard_id);

CREATE TABLE pinboard (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  sort_order INTEGER NOT NULL
);
```

FTS5 virtual table over `text_content` added in Phase 2.

## Privacy rules engine (Phase 2)

- `excluded_bundles` list in settings → watcher drops events whose frontmost
  app matches.
- Always honor pasteboard privacy flags regardless of settings.
- Optional regex scrubbers (credit card / OTP-looking content).

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Focus stealing breaks direct paste | Non-activating panel; test against Safari, Xcode, Electron apps early (Phase 1, not after UI polish) |
| Polling misses rapid copies | 0.3 s interval is the industry norm; acceptable |
| Huge images bloat DB | Blob-on-disk threshold + retention settings |
| Accessibility permission denied | Degrade to copy-to-clipboard mode with a hint |
| CloudKit conflicts (v2) | Items immutable; LWW on metadata only |
