#!/usr/bin/env python3
"""Make Junction's installed absolute paths work from an AppImage mount.

Meson writes /usr, /usr/lib64 and /usr/share into the GJS launcher.  An AppImage
is mounted at a random directory, so those values must be resolved relative to
$APPDIR at runtime.  The shell wrapper also gets a POSIX shebang so it does not
depend on bash being installed on the host.
"""
from __future__ import annotations

import argparse
import re
import stat
import sys
from pathlib import Path


def patch_launcher(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    # imports.package.init({
    #   ...
    #   prefix: "/usr",
    #   libdir: "/usr/lib64",
    #   datadir: "/usr/share",
    # });
    def repl(m: re.Match[str]) -> str:
        indent, key, value = m.group(1), m.group(2), m.group(3)
        rel = value[len("/usr"):]
        return (
            f'{indent}{key}: (GLib.getenv("APPDIR") || "") + '
            f'"/usr{rel}",'
        )

    text = re.sub(
        r'^(\s*)(prefix|libdir|datadir):\s*"(/usr[^"]*)",\s*$',
        repl,
        text,
        flags=re.MULTILINE,
    )

    if text != original:
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return True
    return False


def patch_wrapper(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    # The wrapper only uses POSIX shell features; /bin/sh is always present.
    text = text.replace("#!/usr/bin/env bash", "#!/bin/sh", 1)

    if text != original:
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return True
    return False


def patch_desktop(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    # The AppImage does not ship a D-Bus service file, so let launchers spawn
    # the executable directly.  GApplication still provides single-instance
    # forwarding over the session bus.
    text = text.replace("DBusActivatable=true", "DBusActivatable=false")

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appdir", type=Path)
    args = ap.parse_args()

    appdir = args.appdir.resolve()
    changed = 0

    launcher = appdir / "usr/bin/re.sonny.Junction"
    if launcher.exists() and patch_launcher(launcher):
        print(f"patched {launcher}")
        changed += 1

    wrapper = appdir / "usr/bin/junction"
    if wrapper.exists() and patch_wrapper(wrapper):
        print(f"patched {wrapper}")
        changed += 1

    for desktop in appdir.glob("usr/share/applications/*.desktop"):
        if patch_desktop(desktop):
            print(f"patched {desktop}")
            changed += 1

    if changed == 0:
        print("warning: no Junction paths needed patching", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
