# 05 — Wi-Fi clipboard sync (protocol v1)

Copy on one device, paste on another — Mac, Android, iPhone, Windows, Linux —
when they are on the same network. No account, no cloud, end-to-end
encrypted. This document is the contract every ClipStack app implements: the
Mac app in Swift (`ClipStack/Sync/`), the Flutter apps through the pure-Dart
package `clients/clipstack_sync/`.

## Behaviour

- A copy on any paired device **sets the clipboard on the other devices and
  adds the clip to their history** (like Apple's Universal Clipboard, but
  cross-platform).
- Pairing is one-time: the Mac shows a QR code, the phone scans it.
- Synced kinds: text, link, rich text (with plain-text fallback), images (PNG,
  ≤ 10 MiB by default). Files are not synced in v1 (a path means nothing on
  another device).
- Concealed/transient clipboard items (password managers) are never captured,
  so they are never sent either.

### What each platform can do

| Platform | Sends automatically | Receives automatically | Notes |
|----------|--------------------|------------------------|-------|
| macOS | yes (pasteboard watcher) | yes, sets the clipboard | listener + Bonjour advertiser |
| Windows / Linux | yes | yes | Flutter desktop, planned |
| Android | **no** — Android 10+ blocks background clipboard reads | yes, while the app's foreground service runs | send = share sheet, in-app button, or auto-send when the app opens |
| iOS | no (no background clipboard access) | only while the app is open | share extension to send; Mac↔iPhone already sync via Universal Clipboard with the same Apple ID |

## Discovery

- DNS-SD service type **`_clipstack._tcp`**, domain `local.`
- Instance name: the device name. TXT record keys:
  `v=1`, `id=<device id>`, `name=<device name>`, `pf=<platform>`.
- Listeners prefer TCP port **47474** and fall back to any free port; the real
  port is in the SRV record and the pairing link.
- Networks that block multicast (guest/hotel/campus Wi-Fi, AP isolation) still
  work through the host addresses in the pairing link and the last address a
  peer was seen at.

v1 topology: desktops listen and advertise; phones connect to them. A desktop
that later connects to another desktop does so only when its device id sorts
lower (plain string comparison), so two desktops never dial each other at the
same time. When a new session with a peer becomes ready, any older session
with that peer is closed.

## Identity

- **Device id** — random UUID, lowercase, 36 ASCII characters.
- **Static key** — an X25519 key pair created on first launch, stored in the
  platform keychain/keystore. Never leaves the device except the public half.
- **Platform** — one of `macos`, `android`, `ios`, `windows`, `linux`.
- Binary values in links and JSON use **base64url without padding**.

## Pairing link (QR code)

The listening device shows this link as a QR code while its "Pair a device"
window is open:

```
clipstack://pair?v=1&id=<device id>&name=<url-encoded name>&pf=<platform>
                &pk=<static public key, b64url>&token=<16 random bytes, b64url>
                &port=<port>&hosts=<comma-separated IPv4 addresses>
```

The token is single-use and expires after 5 minutes or when the window
closes. The camera carries the Mac's real public key to the phone, so the
phone can never be tricked into pairing with an impostor; the token proves to
the Mac that the phone saw the QR code.

## Wire format

### Frames

Every message on the TCP stream is a frame: a **u32 big-endian length `N`**
followed by `N` bytes. `N` must be ≤ 16 MiB (16 777 216); a larger length
closes the connection.

### Handshake

The connecting device is the **initiator (I)**, the listening device the
**responder (R)**. I always knows R's static public key `S_R` — from the
pairing link or from an earlier pairing.

1. I → R, plaintext frame, 104 bytes:
   `"CSv1"` (ASCII) ‖ `E_I` (I's fresh ephemeral X25519 public key, 32) ‖
   `S_I` (I's static public key, 32) ‖ `id_I` (36 ASCII bytes).
2. R accepts only if `(id_I, S_I)` is a paired device, **or** its pairing
   window is open (then the first encrypted message must be `pair`). Otherwise
   it closes the connection.
3. R → I, plaintext frame, 36 bytes: `"CSv1"` ‖ `E_R` (32).

Both sides then compute, with `DH(priv, pub)` = X25519:

```
h   = SHA-256( "ClipStack v1 handshake" ‖ frame1 ‖ frame2 )
ee  = DH(e_I, E_R)  = DH(e_R, E_I)
es  = DH(e_I, S_R)  = DH(s_R, E_I)
se  = DH(s_I, E_R)  = DH(e_R, S_I)
okm = HKDF-SHA256(ikm = ee ‖ es ‖ se, salt = h,
                  info = "ClipStack v1 session keys", length = 64)
k_IR = okm[0..32)    I → R direction
k_RI = okm[32..64)   R → I direction
```

A DH result of 32 zero bytes aborts the handshake. `es` and `se` bind both
static keys, so an impostor without the right private key derives different
keys and the first encrypted frame fails to decrypt; `ee` gives forward
secrecy.

### Encrypted frames

Every frame after the handshake is
`ChaCha20-Poly1305(key = direction key, nonce, aad = empty)` and carries
**ciphertext ‖ 16-byte tag**. The nonce is 4 zero bytes ‖ a u64 big-endian
counter that starts at 0 for each direction and increases by 1 per frame. A
frame that fails to decrypt closes the connection.

### Message layout

The decrypted plaintext is:
**u32 big-endian header length `H`** ‖ header (`H` bytes, a UTF-8 JSON object
with at least `"t"`, the message type) ‖ body (the remaining bytes, often
empty). Receivers ignore unknown fields and unknown message types.

### First messages

- Normal connection: I sends `hello`, R answers `hello`.
- Pairing: I sends `pair`; R checks the token, stores I as a paired device and
  answers `paired`; the session then continues as a normal one.
- R checks that `device.id` in `hello`/`pair` equals `id_I` from frame 1.

### Message types

| `t` | Header fields | Body |
|-----|---------------|------|
| `hello` | `device: {id, name, platform}`, `app` (version string) | — |
| `pair` | `token`, `device: {id, name, platform}` | — |
| `paired` | `device: {id, name, platform}` | — |
| `clip` | `id` (UUID), `origin` (device id), `kind` (`text`\|`url`\|`rtf`\|`image`), `text` (all kinds but `image`), `mime` (when a body is present: `text/rtf` or `image/png`), `createdAt` (ms since Unix epoch) | RTF bytes or PNG bytes |
| `ping` / `pong` | — | — |
| `unpair` | — (sender removed this pairing; receiver deletes it and closes) | — |
| `error` | `code` (`bad_token`, `not_paired`, `too_large`, `unsupported`), `message` | — |

Keep-alive: send `ping` after 25 s without receiving anything; close after
60 s without receiving anything.

## Rules every client follows

1. **Never forward** a received clip. Every device is connected to each of its
   peers directly, so only the device where the copy happened sends it.
2. Remember the last 200 received clip ids and drop repeats.
3. When applying a received clip to the system clipboard, make sure the
   clipboard watcher does not treat that change as a new local copy (the Mac
   app marks its own pasteboard writes; desktop Flutter compares against the
   last applied content).
4. Do not send bodies larger than 10 MiB in v1.
5. A received clip appears in history with the sending device's name as its
   source.

## Testing

The Mac app has test hooks that are inert unless the environment variable is
set. Run the binary directly
(`build/DerivedData/Build/Products/Debug/ClipStack.app/Contents/MacOS/ClipStack`)
so they reach it:

| Variable | Effect |
|----------|--------|
| `CLIPSTACK_SUPPORT_DIR=<dir>` | Database, blobs and sync identity live in `<dir>`, never touching real history |
| `CLIPSTACK_DEBUG_PAIR_FILE=<file>` | Sync starts with a pairing window always open; the pairing link is written to `<file>`. Bonjour is off |
| `CLIPSTACK_PASTEBOARD=<name>` | Watch and write a private named pasteboard instead of the system clipboard |
| `CLIPSTACK_DEVICE_NAME=<name>` | Name the Mac shows to peers (store screenshots) |
| `CLIPSTACK_SNAPSHOT_DIR=<dir>` | Debug builds only: render every Settings tab to PNGs and quit |

`clients/clipstack_sync` includes a command-line peer that pairs and exchanges
clips with such an instance:

```sh
cd clients/clipstack_sync
dart run bin/peer.dart pair "$(cat link.txt)" --state peer.json
dart run bin/peer.dart send "hello" --state peer.json
dart run bin/peer.dart listen --state peer.json        # prints clips as JSON lines
```

The Android emulator pairs from the same link:
`adb shell "am start -a android.intent.action.VIEW -d '<link>' com.zamansheikh.clipstack"`.
`dart test` in `clients/clipstack_sync` checks the Dart side against a test
vector produced by the Swift implementation.

## Versioning

Frame 1's `"CSv1"` magic is the protocol version. A future v2 uses `"CSv2"`; a
responder that doesn't speak it closes the connection, and the initiator may
retry with v1.
