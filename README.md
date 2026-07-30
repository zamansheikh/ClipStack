# ClipStack

A free, feature-complete clipboard manager for macOS (and later iOS), inspired by
[Paste](https://apps.apple.com/us/app/paste-limitless-clipboard/id967805235) —
built from scratch, no subscription.

> **Naming note:** "ClipStack" is a working title. Verify App Store / trademark
> availability before shipping. Do not reuse Paste's name, icon, or artwork —
> replicating *features* is fine, copying *branding* is not.

## Docs

| Doc | Purpose |
|-----|---------|
| [docs/01-overview.md](docs/01-overview.md) | Vision, what Paste does, goals |
| [docs/02-feature-spec.md](docs/02-feature-spec.md) | Full feature breakdown to replicate |
| [docs/03-architecture.md](docs/03-architecture.md) | Tech stack, macOS APIs, data model |
| [docs/04-roadmap.md](docs/04-roadmap.md) | MVP → v1 phased plan |

## Status

🔨 Phase 1 (MVP) — core loop implemented: capture → store → overlay → paste.

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate        # regenerate ClipStack.xcodeproj from project.yml
open ClipStack.xcodeproj # build & run from Xcode (⌘R)
```

Or from the CLI:

```sh
xcodebuild -project ClipStack.xcodeproj -scheme ClipStack -configuration Debug build
```

The `.xcodeproj` is generated — edit `project.yml`, not the project file.
