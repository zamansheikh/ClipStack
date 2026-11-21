#!/usr/bin/env python3
"""Builds the Play Store listing graphics and the README showcase images.

Each asset is an HTML page rendered by headless Chrome, then flattened to an
opaque PNG with ffmpeg (Play rejects images with an alpha channel). Inputs are
the raw captures in docs/store/raw/ (real app screenshots) and the brand icons.

    python3 docs/store/generate.py

Needs Google Chrome and ffmpeg. Re-capture docs/store/raw/ after UI changes.
"""

import html
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "docs" / "store"
RAW = STORE / "raw"
ASSETS = ROOT / "docs" / "assets"
# Single home for the Play listing images: where fastlane supply and F-Droid read them.
PLAY = ROOT / "clients" / "clipstack_app" / "fastlane" / "metadata" / "android" / "en-US" / "images"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
LOGO = (ASSETS / "icon.png").as_uri()

# Status bar background sampled from each capture, so the redrawn bar blends in.
STATUS = {
    "welcome-light": ("#f5f4fa", "#1b1b22"),
    "home-light": ("#f5f4fa", "#1b1b22"),
    "sheet-light": ("#707073", "#1b1b22"),
    "settings-light": ("#f5f4fa", "#1b1b22"),
    "home-dark": ("#0f0f16", "#f2f2f7"),
    "images-dark": ("#0f0f16", "#f2f2f7"),
}

BASE_CSS = """
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: %(w)dpx; height: %(h)dpx; overflow: hidden; }
body { font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
       -webkit-font-smoothing: antialiased; }
.canvas { position: relative; width: 100%%; height: 100%%; overflow: hidden; background: var(--bg); }
.blob { position: absolute; border-radius: 50%%; filter: blur(110px); }
.phone { position: absolute; background: #0c0c11;
         box-shadow: 0 50px 110px rgba(38, 28, 96, .34), inset 0 0 0 3px #2b2b35; }
.screen { position: relative; overflow: hidden; aspect-ratio: 1080 / 2400; }
.screen img { width: 100%%; display: block; }
.status { position: absolute; top: 0; left: 0; right: 0; height: 3.75%%;
          display: flex; align-items: center; justify-content: space-between; padding: 0 7%%; }
.status .time { font-weight: 600; letter-spacing: -.2px; }
.status .icons { display: flex; gap: 6%%; align-items: center; height: 100%%; }
.punch { position: absolute; left: 50%%; top: 1.15%%; width: 3.1%%; aspect-ratio: 1; border-radius: 50%%;
         transform: translateX(-50%%); background: #050507; }
"""

WIFI = '<svg viewBox="0 0 24 24" style="height:46%;fill:{c}"><path d="M12 20.5 1.2 9.2a15.3 15.3 0 0 1 21.6 0Z"/></svg>'
BATTERY = ('<svg viewBox="0 0 30 16" style="height:40%;fill:none;stroke:{c};stroke-width:1.6">'
           '<rect x="1" y="1.5" width="24" height="13" rx="3.5"/><rect x="3.2" y="3.7" width="19.6" height="8.6" rx="2" '
           'style="fill:{c};stroke:none"/><path d="M27.4 6v4" stroke-linecap="round"/></svg>')


def phone(shot: str, width: int, position: str) -> str:
    """A phone frame around a real capture, with a clean 9:41 status bar.
    Bezel, corners and status text scale with [width]."""
    bg, ink = STATUS[shot]
    src = (RAW / f"phone-{shot}.png").as_uri()
    bezel = round(width * 0.03)
    style = f"{position};width:{width}px;padding:{bezel}px;border-radius:{round(width * 0.135)}px"
    font_px = round(width * 0.04, 1)
    return f"""
<div class="phone" style="{style}">
  <div class="screen" style="border-radius:{round(width * 0.105)}px">
    <img src="{src}">
    <div class="status" style="background:{bg};color:{ink};font-size:{font_px}px">
      <span class="time">9:41</span>
      <span class="icons">{WIFI.format(c=ink)}{BATTERY.format(c=ink)}</span>
    </div>
    <div class="punch"></div>
  </div>
</div>"""


def page(w: int, h: int, body: str, extra_css: str = "") -> str:
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{BASE_CSS % {'w': w, 'h': h}}{extra_css}</style></head><body>{body}</body></html>"


LIGHT = "--bg: linear-gradient(180deg, #f4f2ff 0%, #e6e1ff 100%); --ink: #16152a; --muted: #5b5878;"
DARK = "--bg: linear-gradient(180deg, #16142a 0%, #0b0b12 100%); --ink: #ffffff; --muted: #a9a6c9;"


def screenshot(title: str, subtitle: str, shot: str, dark: bool, extra: str = "") -> str:
    blobs = ("""<div class="blob" style="width:620px;height:620px;left:-180px;top:-140px;background:#8ab4f8;opacity:.55"></div>
<div class="blob" style="width:700px;height:700px;right:-240px;top:760px;background:#9763ec;opacity:.45"></div>"""
             if not dark else
             """<div class="blob" style="width:640px;height:640px;left:-220px;top:-160px;background:#3b3f9a;opacity:.6"></div>
<div class="blob" style="width:760px;height:760px;right:-260px;top:820px;background:#5b2fa6;opacity:.5"></div>""")
    head = f"""
<div style="position:absolute;top:118px;left:70px;right:70px;text-align:center">
  <h1 style="font-size:82px;line-height:1.06;font-weight:800;letter-spacing:-2.2px;color:var(--ink)">{title}</h1>
  <p style="margin-top:26px;font-size:35px;line-height:1.38;font-weight:500;color:var(--muted)">{subtitle}</p>
</div>"""
    device = phone(shot, 620, "left:50%;top:575px;transform:translateX(-50%)")
    return page(1080, 1920, f'<div class="canvas" style="{DARK if dark else LIGHT}">{blobs}{head}{extra or device}</div>')


def pairing_screenshot() -> str:
    """Phone (welcome screen) with the Mac's QR pairing sheet floating beside it."""
    mac = (RAW / "mac-pairing-light.png").as_uri()
    extra = phone("welcome-light", 600, "left:410px;top:575px") + f"""
<div style="position:absolute;left:44px;top:1160px;width:620px;border-radius:26px;overflow:hidden;
            box-shadow:0 40px 90px rgba(38,28,96,.30), 0 0 0 1px rgba(0,0,0,.06);background:#fff">
  <div style="height:44px;background:#f1f0f4;display:flex;align-items:center;gap:10px;padding:0 18px;border-bottom:1px solid #e3e2e8">
    <span style="width:14px;height:14px;border-radius:50%;background:#ff5f57"></span>
    <span style="width:14px;height:14px;border-radius:50%;background:#febc2e"></span>
    <span style="width:14px;height:14px;border-radius:50%;background:#28c840"></span>
    <span style="margin-left:14px;font-size:19px;font-weight:600;color:#55545e">ClipStack on your Mac</span>
  </div>
  <img src="{mac}" style="width:100%;display:block">
</div>"""
    return screenshot("Pair in seconds.", "Scan the code on your Mac.<br>No account, no sign-up.", "welcome-light", False, extra)


def feature_graphic() -> str:
    chips = "".join(
        f'<span style="padding:7px 15px;border-radius:999px;background:rgba(255,255,255,.18);'
        f'border:1px solid rgba(255,255,255,.28);font-size:15px;font-weight:600;color:#fff">{html.escape(t)}</span>'
        for t in ["Mac ⇄ Android", "End-to-end encrypted", "No cloud"]
    )
    body = f"""
<div class="canvas" style="--bg: linear-gradient(120deg, #7fa6f6 0%, #7b80f2 48%, #9763ec 100%)">
  <div class="blob" style="width:520px;height:520px;left:-160px;top:-260px;background:#cfe0ff;opacity:.45"></div>
  <div class="blob" style="width:520px;height:520px;right:-120px;bottom:-300px;background:#5d2ed1;opacity:.45"></div>
  <div style="position:absolute;left:62px;top:78px;width:600px">
    <div style="display:flex;align-items:center;gap:18px">
      <img src="{LOGO}" style="width:104px;height:104px;margin:-9px;filter:drop-shadow(0 14px 24px rgba(40,20,110,.35))">
      <div style="font-size:66px;font-weight:800;letter-spacing:-1.8px;color:#fff">ClipStack</div>
    </div>
    <div style="margin-top:24px;font-size:34px;line-height:1.18;font-weight:700;color:#fff;letter-spacing:-.6px">
      Your clipboard, on every device.</div>
    <div style="margin-top:12px;font-size:19px;line-height:1.4;color:rgba(255,255,255,.88)">
      Copy on your Mac, paste on your phone — over your own Wi-Fi.</div>
    <div style="margin-top:24px;display:flex;gap:8px">{chips}</div>
  </div>
  {phone("home-dark", 262, "right:86px;top:44px;transform:rotate(6deg)")}
</div>"""
    return page(1024, 500, body)


def showcase() -> str:
    """Wide README banner: four phones, staggered."""
    phones = "".join([
        phone("home-light", 420, "left:70px;top:150px"),
        phone("home-dark", 420, "left:540px;top:80px"),
        phone("sheet-light", 420, "left:1010px;top:150px"),
        phone("settings-light", 420, "left:1480px;top:80px"),
    ])
    body = f"""<div class="canvas" style="{LIGHT}">
  <div class="blob" style="width:700px;height:700px;left:-200px;top:-300px;background:#8ab4f8;opacity:.5"></div>
  <div class="blob" style="width:800px;height:800px;right:-260px;bottom:-420px;background:#9763ec;opacity:.42"></div>
  {phones}</div>"""
    return page(1970, 1040, body)


def sync_banner() -> str:
    """README: the Mac pairing sheet next to the phone it pairs with."""
    mac = (RAW / "mac-pairing-light.png").as_uri()
    body = f"""<div class="canvas" style="{LIGHT}">
  <div class="blob" style="width:640px;height:640px;left:-220px;top:-260px;background:#8ab4f8;opacity:.5"></div>
  <div class="blob" style="width:700px;height:700px;right:-200px;bottom:-380px;background:#9763ec;opacity:.42"></div>
  <div style="position:absolute;left:70px;top:150px;width:900px;border-radius:30px;overflow:hidden;background:#fff;
              box-shadow:0 40px 100px rgba(38,28,96,.28), 0 0 0 1px rgba(0,0,0,.06)">
    <div style="height:52px;background:#f1f0f4;display:flex;align-items:center;gap:12px;padding:0 22px;border-bottom:1px solid #e3e2e8">
      <span style="width:16px;height:16px;border-radius:50%;background:#ff5f57"></span>
      <span style="width:16px;height:16px;border-radius:50%;background:#febc2e"></span>
      <span style="width:16px;height:16px;border-radius:50%;background:#28c840"></span>
      <span style="margin-left:16px;font-size:22px;font-weight:600;color:#55545e">ClipStack Settings → Devices → Pair a Device</span>
    </div>
    <img src="{mac}" style="width:100%;display:block">
  </div>
  <div style="position:absolute;left:1010px;top:470px;font-size:64px;color:#7b80f2;font-weight:300">⇄</div>
  {phone("home-light", 430, "left:1120px;top:70px")}
</div>"""
    return page(1640, 1040, body)


SCREENSHOTS = [
    ("01-copy-paste", lambda: screenshot("Copy on your Mac.<br>Paste on your phone.",
                                          "Your clipboard syncs over Wi-Fi, instantly.", "home-light", False)),
    ("02-organized", lambda: screenshot("Every clip,<br>beautifully organized.",
                                        "Text, links and images in one grid —<br>in light or dark.", "home-dark", True)),
    ("03-tap-to-copy", lambda: screenshot("Tap to copy.<br>Hold for details.",
                                          "Any clip back on your clipboard<br>in one tap.", "sheet-light", False)),
    ("04-pair", pairing_screenshot),
    ("05-private", lambda: screenshot("Private by design.",
                                      "End-to-end encrypted, device to device.<br>Nothing touches the cloud.", "settings-light", False)),
    ("06-images", lambda: screenshot("Screenshots,<br>straight to your phone.",
                                     "Copy an image on your Mac and it's<br>on your phone's clipboard.", "images-dark", True)),
]


def render(markup: str, size: tuple, dest: Path, work: Path) -> None:
    src = work / (dest.stem + ".html")
    src.write_text(markup, encoding="utf-8")
    shot = work / (dest.stem + "-rgba.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--allow-file-access-from-files", f"--window-size={size[0]},{size[1]}",
                    f"--screenshot={shot}", src.as_uri()], check=True, capture_output=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Opaque 24-bit PNG: Play requires no alpha channel.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(shot), "-vf", f"crop={size[0]}:{size[1]}:0:0",
                    "-pix_fmt", "rgb24", str(dest)], check=True)
    print("wrote", dest.relative_to(ROOT))


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for name, make in SCREENSHOTS:
            render(make(), (1080, 1920), PLAY / "phoneScreenshots" / f"{name}.png", work)
        render(feature_graphic(), (1024, 500), PLAY / "featureGraphic.png", work)
        render(showcase(), (1970, 1040), ASSETS / "android-showcase.png", work)
        render(sync_banner(), (1640, 1040), ASSETS / "sync-pairing.png", work)

    # Store icon: the full-bleed app icon (Play rounds the corners itself).
    icon = PLAY / "icon.png"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i",
                    str(ROOT / "clients/clipstack_app/assets/brand/app_icon_full.png"),
                    "-vf", "scale=512:512:flags=lanczos", "-pix_fmt", "rgb24", str(icon)], check=True)
    print("wrote", icon.relative_to(ROOT))


if __name__ == "__main__":
    main()
