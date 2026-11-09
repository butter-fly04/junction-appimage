#!/usr/bin/env python3
"""Make Junction register the desktop file that is actually installed.

Junction hardcodes ``re.sonny.Junction.desktop`` when it calls ``gio mime``.
Integration tools are free to name the desktop file after the AppImage instead
(for example Gear Lever turns ``junction.appimage`` into ``junction.desktop``),
so the hardcoded id names no file and the desktop silently falls back to
another browser.

Resolve the id at runtime from the desktop entry whose command line launches
``$APPIMAGE``.  The upstream id stays as the fallback for a standard install.
"""
from __future__ import annotations

import sys
from pathlib import Path

HARDCODED = "re.sonny.Junction.desktop"

IMPORTS = (
    'import Gio from "gi://Gio";\n'
    'import GLib from "gi://GLib";\n'
)

HELPER = """// An integration tool may install this AppImage under a desktop-file id other
// than the one upstream assumes.  Use the entry that names this AppImage, so
// `gio mime` always points at a file that exists.
function desktopId() {
  const image = GLib.getenv("APPIMAGE");
  if (!image) return "re.sonny.Junction.desktop";

  let hidden = null;
  for (const app of Gio.AppInfo.get_all()) {
    const id = app.get_id();
    const command = app.get_commandline();
    if (!id || !command || !command.includes(image)) continue;
    if (app.should_show()) return id;
    if (!hidden) hidden = id;
  }
  return hidden || "re.sonny.Junction.desktop";
}
"""

REPLACEMENTS = (
    (
        '"gio mime x-scheme-handler/https re.sonny.Junction.desktop"',
        '`gio mime x-scheme-handler/https ${desktopId()}`',
    ),
    (
        '"gio mime x-scheme-handler/http re.sonny.Junction.desktop"',
        '`gio mime x-scheme-handler/http ${desktopId()}`',
    ),
    (
        '`gio mime ${type} re.sonny.Junction.desktop`',
        '`gio mime ${type} ${desktopId()}`',
    ),
)


def main() -> int:
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    if "function desktopId()" in text:
        print(f"{path}: already patched")
        return 0

    missing = [old for old, _ in REPLACEMENTS if old not in text]
    if missing:
        print(
            f"{path}: expected call sites not found: {missing}",
            file=sys.stderr,
        )
        return 1

    anchor = 'import Gdk from "gi://Gdk";\n'
    if anchor not in text:
        print(f"{path}: Gdk import anchor not found", file=sys.stderr)
        return 1
    text = text.replace(anchor, anchor + IMPORTS, 1)

    anchor = "export default function Welcome"
    if anchor not in text:
        print(f"{path}: Welcome export anchor not found", file=sys.stderr)
        return 1
    text = text.replace(anchor, HELPER + "\n" + anchor, 1)

    for old, new in REPLACEMENTS:
        text = text.replace(old, new)

    remaining = text.count(HARDCODED)
    expected = HELPER.count(HARDCODED)
    if remaining != expected:
        print(
            f"{path}: {remaining} hardcoded ids remain, expected {expected}",
            file=sys.stderr,
        )
        return 1

    path.write_text(text, encoding="utf-8")
    print(f"{path}: patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
