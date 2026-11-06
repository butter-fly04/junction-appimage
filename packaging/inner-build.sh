#!/usr/bin/env bash
# Runs inside the Fedora build container.  Builds Junction, assembles a
# relocatable AppDir, bundles the runtime closure and produces an AppImage.
set -euo pipefail

: "${DISTRO:?}"
: "${NAME:?}"
: "${SRC:?}"
: "${WORK:?}"
: "${OUT:?}"
: "${PACKAGING:?}"
: "${TOOLS:?}"

export LC_ALL=C.UTF-8
export APPIMAGE_EXTRACT_AND_RUN=1

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }

APPDIR="$WORK/AppDir"
BUILD="$WORK/build"

# Copy the *contents* of a directory.  `cp -a src dst` nests when dst already
# exists, which is how a stray hicolor/hicolor tree crept into an earlier
# AppDir.
copy_tree() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  cp -a "$src"/. "$dst"/
}

# Fedora ships some GLib helpers with a -64 suffix (gdk-pixbuf-query-loaders-64,
# gio-querymodules-64).  Resolve either spelling.
find_tool() {
  local name
  for name in "$@"; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Build and install Junction
# ---------------------------------------------------------------------------
build_app() {
  log "Configuring Junction"
  rm -rf "$BUILD" "$APPDIR"
  mkdir -p "$APPDIR"

  meson setup "$BUILD" "$SRC" \
    --prefix=/usr \
    --buildtype=release

  log "Compiling"
  ninja -C "$BUILD"

  log "Installing into AppDir"
  DESTDIR="$APPDIR" ninja -C "$BUILD" install
}

patch_paths() {
  log "Making installed paths relocatable"
  python3 "$PACKAGING/patch-config.py" "$APPDIR"

  # The AppImage is launched directly by AppRun, not through D-Bus activation.
  # Shipping a .service file that points at /usr/bin/junction would only cause
  # a launcher to try the wrong executable.
  rm -f "$APPDIR/usr/share/dbus-1/services/re.sonny.Junction.service"
  rmdir "$APPDIR/usr/share/dbus-1/services" 2>/dev/null || true
  rmdir "$APPDIR/usr/share/dbus-1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# GJS runtime
# ---------------------------------------------------------------------------
bundle_gjs() {
  log "Bundling GJS"
  local gjs
  gjs="$(command -v gjs)"
  install -Dm755 "$gjs" "$APPDIR/usr/bin/gjs"

  # Newer GJS splits the engine into libgjs; it is pulled in by the ELF
  # closure, but copy it early so the binary can be smoke-tested.
  for f in /usr/lib64/libgjs.so* /usr/lib/libgjs.so*; do
    [ -e "$f" ] && cp -a "$f" "$APPDIR/usr/lib/" 2>/dev/null || true
  done

  # Junction runs `gio mime ...` to register itself as a default handler.
  # Fedora's host provides /usr/bin/gio, but minimal Ubuntu images do not.
  local gio
  gio="$(command -v gio)"
  install -Dm755 "$gio" "$APPDIR/usr/bin/gio"

  # GJS ships its private GObject-Introspection bindings in a separate
  # directory.  They must be present both in the normal typelib path (for
  # hosts without gjs) and in the package-private path that pkg.init()
  # prepends (libdir + app id).
  local priv="/usr/lib64/gjs/girepository-1.0/GjsPrivate-1.0.typelib"
  if [ -f "$priv" ]; then
    install -Dm644 "$priv" \
      "$APPDIR/usr/lib64/gjs/girepository-1.0/GjsPrivate-1.0.typelib"
    install -Dm644 "$priv" \
      "$APPDIR/usr/lib64/girepository-1.0/GjsPrivate-1.0.typelib"
    install -Dm644 "$priv" \
      "$APPDIR/usr/lib64/re.sonny.Junction/girepository-1.0/GjsPrivate-1.0.typelib"
  else
    warn "GjsPrivate typelib not found"
  fi
}

# GJS hardcodes its private typelib directory as <libdir>/gjs.  On a host that
# also has gjs installed that would win over the bundled copy, so redirect the
# compiled-in path to a fixed symlink that AppRun points at this AppImage.
patch_gjs() {
  log "Relocating GJS private typelib lookup"
  python3 - "$APPDIR" <<'PY'
import sys
from pathlib import Path

appdir = Path(sys.argv[1])
old = b"/usr/lib64/gjs"
new = b"/tmp/.junction"
assert len(old) == len(new)
patched = 0
for path in appdir.rglob("libgjs.so*"):
    if path.is_symlink() or not path.is_file():
        continue
    data = path.read_bytes()
    if old in data:
        path.write_bytes(data.replace(old, new))
        patched += 1
print(f"patched {patched} libgjs copies")
PY
}

# ---------------------------------------------------------------------------
# GObject data: typelibs, schemas, icons, modules
# ---------------------------------------------------------------------------
bundle_data() {
  log "Bundling GIR typelibs"
  local tl src
  # Exact transitive typelib closure of Gtk 4.0 + Adw 1 + Xdp 1.0 + XdpGtk4
  # + GioUnix, as reported by g-ir-inspect.
  local -a typelibs=(
    GLib-2.0 GObject-2.0 Gio-2.0 GioUnix-2.0 GLibUnix-2.0 GModule-2.0
    Gtk-4.0 Gdk-4.0 Gsk-4.0 GdkPixbuf-2.0
    Adw-1 Xdp-1.0 XdpGtk4-1.0
    Pango-1.0 PangoCairo-1.0 cairo-1.0 Graphene-1.0
    HarfBuzz-0.0 freetype2-2.0 GIRepository-3.0
  )
  install -d "$APPDIR/usr/lib64/girepository-1.0"
  for tl in "${typelibs[@]}"; do
    src=""
    for src in "/usr/lib64/girepository-1.0/$tl.typelib" \
               "/usr/lib/girepository-1.0/$tl.typelib"; do
      [ -f "$src" ] && break
    done
    if [ -f "$src" ]; then
      cp -a "$src" "$APPDIR/usr/lib64/girepository-1.0/"
    else
      warn "typelib $tl not found"
    fi
  done

  log "Bundling GSettings schemas"
  copy_tree /usr/share/glib-2.0/schemas "$APPDIR/usr/share/glib-2.0/schemas"
  glib-compile-schemas --targetdir="$APPDIR/usr/share/glib-2.0/schemas" \
    "$APPDIR/usr/share/glib-2.0/schemas"

  log "Bundling icons and themes"
  copy_tree /usr/share/icons/hicolor "$APPDIR/usr/share/icons/hicolor"
  copy_tree /usr/share/icons/Adwaita "$APPDIR/usr/share/icons/Adwaita"
  copy_tree /usr/share/icons/Adwaita-dark "$APPDIR/usr/share/icons/Adwaita-dark"
  # Cursors are looked up through XCURSOR_PATH and the host theme; the app does
  # not need its own copy.
  rm -rf "$APPDIR/usr/share/icons/Adwaita/cursors"

  log "Bundling GdkPixbuf loaders"
  # gdk-pixbuf 2.44 has built-in loaders and ships no .so modules.  Only copy
  # the directory (and the query helper) when a distribution still splits them
  # out; otherwise this is intentionally a no-op.
  copy_tree /usr/lib64/gdk-pixbuf-2.0 "$APPDIR/usr/lib64/gdk-pixbuf-2.0"
  local tool
  if [ -n "$(find /usr/lib64/gdk-pixbuf-2.0 -name '*.so' -print -quit 2>/dev/null)" ]; then
    if tool="$(find_tool gdk-pixbuf-query-loaders gdk-pixbuf-query-loaders-64)"; then
      install -Dm755 "$tool" "$APPDIR/usr/bin/gdk-pixbuf-query-loaders"
    fi
  fi

  log "Bundling GIO modules"
  install -d "$APPDIR/usr/lib64/gio/modules"
  # dconf is the only GIO module Junction needs (for persistent GSettings).
  # Avoid copying TLS/proxy modules and their large dependency closures.
  for m in libdconfsettings.so; do
    if [ -f "/usr/lib64/gio/modules/$m" ]; then
      cp -a "/usr/lib64/gio/modules/$m" "$APPDIR/usr/lib64/gio/modules/"
    else
      warn "GIO module $m not found"
    fi
  done
  if tool="$(find_tool gio-querymodules gio-querymodules-64)"; then
    "$tool" "$APPDIR/usr/lib64/gio/modules" || true
  fi

  log "Bundling GTK modules"
  copy_tree /usr/lib64/gtk-4.0 "$APPDIR/usr/lib64/gtk-4.0"

  log "Bundling Junction translations"
  if [ -d /usr/share/locale ]; then
    local f rel
    while IFS= read -r -d '' f; do
      rel="${f#/usr/share/locale/}"
      install -Dm644 "$f" "$APPDIR/usr/share/locale/$rel"
    done < <(find /usr/share/locale -path '*/LC_MESSAGES/re.sonny.Junction.mo' -print0)
  fi
}

# ---------------------------------------------------------------------------
# ELF closure and RPATHs
# ---------------------------------------------------------------------------
set_rpaths() {
  log "Setting relocatable RPATHs"
  local f dir rel_lib rel_lib64 is_so
  while IFS= read -r -d '' f; do
    # usr/lib is a flat directory; its objects resolve each other through
    # $ORIGIN implicitly and through LD_LIBRARY_PATH at runtime.
    case "$f" in
      "$APPDIR"/usr/lib/*) continue ;;
    esac
    if ! readelf -d "$f" 2>/dev/null | grep -q 'NEEDED'; then
      continue
    fi
    is_so=0
    case "$f" in
      *.so|*.so.*) is_so=1 ;;
    esac
    if [ "$is_so" = 0 ] && \
       ! readelf -l "$f" 2>/dev/null | grep -q 'INTERP'; then
      continue
    fi
    dir="$(dirname "$f")"
    rel_lib="$(realpath --relative-to="$dir" "$APPDIR/usr/lib")"
    rel_lib64="$(realpath --relative-to="$dir" "$APPDIR/usr/lib64")"
    patchelf --set-rpath "\$ORIGIN/$rel_lib:\$ORIGIN/$rel_lib64" "$f" \
      || warn "could not set RPATH on $f"
  done < <(find "$APPDIR/usr/bin" "$APPDIR/usr/libexec" \
                "$APPDIR/usr/lib64" \
                -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) \
                -print0 2>/dev/null)
}

bundle_elf() {
  log "Bundling ELF dependency closure"
  python3 "$PACKAGING/bundle-libs.py" "$APPDIR"
  set_rpaths
  patch_gjs
}

# ---------------------------------------------------------------------------
# AppImage metadata and packaging
# ---------------------------------------------------------------------------
install_metadata() {
  log "Preparing AppImage metadata"
  local desktop icon png icon_name
  desktop="$APPDIR/usr/share/applications/re.sonny.Junction.desktop"
  icon="$APPDIR/usr/share/icons/hicolor/scalable/apps/re.sonny.Junction.svg"

  if [ -f "$desktop" ]; then
    cp "$desktop" "$APPDIR/"
  else
    warn "no desktop file installed"
  fi

  if [ -f "$icon" ]; then
    cp "$icon" "$APPDIR/re.sonny.Junction.svg"
    png="re.sonny.Junction.png"
    if command -v rsvg-convert >/dev/null 2>&1; then
      rsvg-convert -w 256 -h 256 "$icon" -o "$APPDIR/$png"
    elif command -v convert >/dev/null 2>&1; then
      convert -background none "$icon" -resize 256x256 "$APPDIR/$png"
    else
      warn "no SVG-to-PNG converter; .DirIcon will be SVG"
      png="re.sonny.Junction.svg"
    fi
    ln -sfn "$png" "$APPDIR/.DirIcon"
  else
    warn "application icon not found"
  fi

  install -Dm755 "$PACKAGING/AppRun" "$APPDIR/AppRun"
}

fetch_appimagetool() {
  local tool="$TOOLS/appimagetool-x86_64.AppImage"
  if [ ! -s "$tool" ]; then
    log "Downloading appimagetool" >&2
    curl -fL --retry 3 -o "$tool" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$tool"
  fi
  printf '%s\n' "$tool"
}

make_appimage() {
  log "Building AppImage"
  local version tool outfile comp
  local -a squashfs_args runtime_args
  version="$(grep -m1 -E "^[[:space:]]*version[[:space:]]*:" "$SRC/meson.build" \
    | sed -E "s/.*version[[:space:]]*:[[:space:]]*'([^']+)'.*/\1/")"
  [ -n "$version" ] || version="unknown"
  tool="$(fetch_appimagetool)"
  outfile="$OUT/Junction-${version}-${NAME}-x86_64.AppImage"

  runtime_args=()
  if [ -s "$TOOLS/runtime-x86_64" ]; then
    runtime_args+=(--runtime-file "$TOOLS/runtime-x86_64")
  else
    warn "no cached AppImage runtime; appimagetool will try to download it"
  fi

  # The appimagetool binary bundles a minimal mksquashfs that only supports
  # zstd.  Level 19 is a little smaller than the default 15 at an acceptable
  # build-time cost.
  comp="${APPIMAGE_COMPRESS:-zstd}"
  squashfs_args=()
  if [ "$comp" = "zstd" ]; then
    squashfs_args+=(--comp zstd
      --mksquashfs-opt=-Xcompression-level
      --mksquashfs-opt="${APPIMAGE_COMPRESS_LEVEL:-19}")
  else
    squashfs_args+=(--comp "$comp")
  fi

  rm -f "$outfile"
  ARCH=x86_64 "$tool" "${runtime_args[@]}" "${squashfs_args[@]}" \
    "$APPDIR" "$outfile"
  chmod +x "$outfile"
  echo "$outfile"
}

build_app
patch_paths
bundle_gjs
bundle_data
bundle_elf
install_metadata
make_appimage

log "Build complete"
