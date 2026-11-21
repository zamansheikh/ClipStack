# Store assets

Google Play listing graphics for the Android app, generated from real app
screenshots by [`generate.py`](generate.py). They live with the listing text in
[`clients/clipstack_app/fastlane/metadata/android/en-US/`](../../clients/clipstack_app/fastlane/metadata/android/en-US),
the layout `fastlane supply` and F-Droid read:

| File | Play Console field | Spec |
|------|--------------------|------|
| `images/icon.png` | App icon | 512 × 512 PNG, full-bleed (Play rounds the corners) |
| `images/featureGraphic.png` | Feature graphic | 1024 × 500 PNG, no alpha |
| `images/phoneScreenshots/*.png` | Phone screenshots (6) | 1080 × 1920 PNG, no alpha |
| `title.txt`, `short_description.txt`, `full_description.txt` | Store listing | 30 / 80 / 4000 characters max |
| `changelogs/<versionCode>.txt` | Release notes | 500 characters max |

## Regenerating

```sh
python3 docs/store/generate.py   # needs Google Chrome and ffmpeg
```

Each graphic is an HTML page rendered by headless Chrome, then flattened to an
opaque PNG. The phones show the captures in [`raw/`](raw), with a clean 9:41
status bar drawn over them. After UI changes, re-capture `raw/` from the
emulator: name the emulator `Pixel 9 Pro`, run the Mac test instance with
`CLIPSTACK_DEVICE_NAME="MacBook Pro"` (test hooks are listed in
[`docs/05-lan-sync.md`](../05-lan-sync.md#testing)), and use sample clips, not
personal ones.

The README images [`docs/assets/android-showcase.png`](../assets/android-showcase.png)
and [`docs/assets/sync-pairing.png`](../assets/sync-pairing.png) come from the
same script.
