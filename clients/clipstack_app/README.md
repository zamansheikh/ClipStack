# ClipStack for Android

The phone side of ClipStack's Wi-Fi clipboard sync, in Flutter. Android today;
the same app will become the iPhone, Windows and Linux clients.

- Pairs with the Mac app by QR code (or a `clipstack://pair` link).
- Copies made on the Mac land on the phone's clipboard, also in the
  background (a foreground service keeps the connection open).
- Sends from the phone: **Send clipboard**, **Share → ClipStack**, or
  automatically when the app opens (Android only allows clipboard reads while
  an app is in front).
- History grid of text, links and images; light and dark themes.

## Run

```sh
flutter run --release
```

Then on the Mac: **ClipStack → Settings → Devices → Pair a Device**, and scan
the code from the app.

## Layout

| Path | What's there |
|------|--------------|
| `lib/src/sync_controller.dart` | Pairing, reconnecting, sending, applying received clips |
| `lib/src/discovery.dart` | mDNS discovery of `_clipstack._tcp` listeners |
| `lib/src/storage.dart` | Keystore-backed identity, paired computers, history |
| `lib/src/ui/` | Screens, theme and widgets |
| `android/app/src/main/kotlin/…/MainActivity.kt` | Share sheet and pairing links, clipboard images, image → PNG |
| `android/app/src/main/kotlin/…/KeepAliveService.kt` | Foreground service that keeps sync alive in the background |
| `fastlane/metadata/android/en-US/` | Google Play listing text and graphics |

The protocol itself is in [`../clipstack_sync`](../clipstack_sync) and
specified in [`docs/05-lan-sync.md`](../../docs/05-lan-sync.md).

## Icons

Launcher icons come from `assets/brand/` (split from the Mac app icon into
gradient and glyph layers). After changing them:

```sh
dart run flutter_launcher_icons
```
