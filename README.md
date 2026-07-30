<div align="center">

<img src="docs/assets/icon.png" alt="ClipStack icon" width="128" height="128">

# ClipStack

**A free, native clipboard manager for macOS — unlimited history, pinboards, instant search.**

[![Latest release](https://img.shields.io/github/v/release/zamansheikh/ClipStack?label=download&color=blue)](https://github.com/zamansheikh/ClipStack/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Everything you copy — text, links, images, files — captured silently, searchable forever,
and pasteable anywhere with one keystroke. Inspired by paid apps like Paste,
built from scratch with no subscription, no account, and no data ever leaving your Mac.

[**⬇ Download the latest release**](https://github.com/zamansheikh/ClipStack/releases/latest)

</div>

---

## ✨ Features

- 📋 **Unlimited clipboard history** — every copy is captured automatically: plain & rich text, links, images, and files, with source-app attribution.
- ⌨️ **Overlay paste board** — press `⌘⇧V` for a bottom-anchored overlay of preview cards. It never steals focus, so pasting lands exactly where you were typing.
- 🔍 **Instant full-text search** — type to search your *entire* history (SQLite FTS5, prefix matching), with Text / Links / Images / Files filter chips.
- 📌 **Pins & pinboards** — pin anything (`⌘P`) so it never expires; organize pins into named boards (email templates, snippets, addresses…).
- 📚 **Paste stack** — `⌘`-click multiple cards, hit `Return`, and they paste sequentially — perfect for filling forms.
- 👁️ **Preview & edit** — `Space` opens a full-size preview; edit text clips in place before pasting.
- 🔒 **Privacy first** — password-manager copies are never recorded (honors concealed/transient clipboard flags), you can exclude any app entirely, and everything stays in a local SQLite database. No cloud, no telemetry.
- ⏱️ **Retention controls** — auto-delete history after 1 hour → 1 month, cap item count or size, clear by category. Pinned clips always survive.
- ⚙️ **Native & lightweight** — Swift + SwiftUI menu bar app, ~2 MB, launch at login, remappable hotkey.

## ⌨️ Keyboard shortcuts

| Key | Action |
|-----|--------|
| `⌘⇧V` | Open / close the overlay (remappable) |
| `←` `→` | Navigate cards |
| `Return` | Paste into the frontmost app |
| `⇧Return` | Paste as plain text |
| `⌘1`–`⌘9` | Quick-paste item 1–9 |
| `Space` | Full-size preview (and edit text) |
| `⌘P` | Pin / unpin |
| `⌘C` | Copy without pasting |
| `⌘⌫` | Delete clip |
| `⌘click` | Add to paste stack |
| `Tab` | Cycle History → Pinned → pinboards |
| `Esc` | Dismiss |

## 📦 Install

1. Download the latest `ClipStack-x.y.z.zip` from [**Releases**](https://github.com/zamansheikh/ClipStack/releases/latest), unzip, and move **ClipStack.app** to **Applications**.
2. The app isn't notarized by Apple yet, so macOS blocks the first launch. Paste this one command in **Terminal** and press Enter:

   ```sh
   xattr -d com.apple.quarantine /Applications/ClipStack.app
   ```

3. Open ClipStack (it lives in your menu bar) and press `⌘⇧V`.
4. *Optional:* grant the **Accessibility** permission when asked so items paste directly into other apps — or skip it and use copy-only mode.

### Requirements

macOS 14 (Sonoma) or later, Apple Silicon.

## 🛠 Building from source

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
git clone https://github.com/zamansheikh/ClipStack.git
cd ClipStack
xcodegen generate
open ClipStack.xcodeproj   # then ⌘R
```

The `.xcodeproj` is generated — edit [`project.yml`](project.yml), not the project file.

## 🗺 Roadmap & docs

| Doc | Purpose |
|-----|---------|
| [docs/01-overview.md](docs/01-overview.md) | Vision & goals |
| [docs/02-feature-spec.md](docs/02-feature-spec.md) | Full feature specification |
| [docs/03-architecture.md](docs/03-architecture.md) | Tech stack, macOS APIs, data model |
| [docs/04-roadmap.md](docs/04-roadmap.md) | Phased plan — Phases 0–2 complete ✅ |

**Up next:** Developer ID signing + notarization (no more Terminal command), iCloud sync, and an iOS companion app.

## 🤝 Contributing

Issues and pull requests are welcome! If you'd like to help:

1. Check the [roadmap](docs/04-roadmap.md) and [open issues](https://github.com/zamansheikh/ClipStack/issues) for ideas.
2. Fork, create a feature branch, and open a PR against `main`.
3. For larger changes, open an issue first so we can discuss the approach.

## ☕ Support the project

ClipStack is free and always will be. If it saves you a subscription, consider buying me a coffee — it funds the Apple Developer account that will make installs one-click (signing + notarization).

<p>
<a href="https://ko-fi.com/zamansheikh"><img src="https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=ko-fi&logoColor=white" alt="Support on Ko-fi" height="32"></a>
&nbsp;
<a href="https://buymeacoffee.com/zamansheikh"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy Me a Coffee" height="32"></a>
</p>

## 📄 License

[MIT](LICENSE) © Zaman Sheikh

> **Naming note:** "ClipStack" is a working title — trademark / App Store availability not yet verified. ClipStack replicates *features* of commercial clipboard managers, not their branding.
