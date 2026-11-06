# Junction AppImage — Complete Build Process (Fedora 44)

This document describes the final, verified build process for the Junction
AppImage. It covers the host-side driver, the Podman build image, every step
inside the container, GJS-specific relocation, and the validation used for the
published artifact.

- **Application:** Junction 1.13 (GTK4/libadwaita GJS application)
- **Build target:** Fedora 44, x86_64
- **Artifact:** `dist/Junction-1.13-fedora44-x86_64.AppImage`
- **Size:** about 54 MB
- **Compression:** SquashFS, zstd level 19
- **Host policy:** everything runs in rootless Podman; the host is not
  modified and no host packages are installed.

---

## 1. Repository layout

```
build.sh                     Host driver: checkout, image, container run
.github/workflows/build.yml  CI: resolve tag, build, test, release
packaging/
  Containerfile.fedora44     Self-contained Fedora 44 build image
  inner-build.sh             Build + AppDir assembly, runs in the container
  latest-tag.sh              Finds the newest upstream version tag
  bundle-libs.py             ELF dependency closure (without glibc/NSS)
  patch-config.py            Launcher/desktop relocation
  AppRun                     Runtime environment, launcher and self-test
  test-appimage.sh           Clean-container smoke test
src/                         Junction checkout (created by build.sh)
tools/                       appimagetool + runtime (cached)
work/fedora44/               Build tree and AppDir
dist/                        Output AppImage
```

`src/`, `work/`, `tools/` and `dist/` are generated and git-ignored.

---

## 2. Prerequisites

- A host with rootless Podman
- Network access to Fedora mirrors and GitHub

The build image is self-contained and starts from `quay.io/fedora/fedora:44`.
No separately prepared Apostrophe image is required. `BASE_IMAGE` can still be
overridden to layer on an existing Fedora 44 image.

---

## 3. Reproducing the build

```bash
cd junction
./build.sh fedora44
```

Useful variants:

```bash
JUNCTION_TAG=v1.12 ./build.sh fedora44             # build another release
BASE_IMAGE=localhost/apostrophe-build:fedora44 \
  ./build.sh fedora44                              # reuse a local base image
FORCE_IMAGE=1 ./build.sh fedora44                  # rebuild the Podman image
APPIMAGE_COMPRESS_LEVEL=22 ./build.sh fedora44     # slightly smaller/slower
packaging/test-appimage.sh dist/Junction-*-fedora44-x86_64.AppImage
```

---

## 4. Host-side driver (`build.sh`)

`build.sh` orchestrates the build from the host:

1. Selects Fedora 44 and the image names.
2. Clones the requested tag into `src/`, re-cloning when the existing checkout
   is at a different tag.
3. Ensures the `troll/gjspack` submodule is initialized, because the
   prebuilt `gjspack` resource generator is part of the build.
4. Creates `work/fedora44/`, `dist/` and `tools/`.
5. Downloads `appimagetool` and the type-2 runtime into `tools/` when missing.
6. Copies the checkout to `work/fedora44/src` and removes `.git` from both the
   copy and `troll/`, keeping the build deterministic.
7. Reuses `localhost/junction-build:fedora44` when it exists; rebuilds it from
   `packaging/Containerfile.fedora44` when `FORCE_IMAGE=1` or when missing.
8. Runs `packaging/inner-build.sh` in the container with the repository mounted
   at `/work` and the same environment contract as the other AppImage builds.
9. Prints the artifacts in `dist/`.

---

## 5. Build image (`packaging/Containerfile.fedora44`)

```dockerfile
ARG BASE_IMAGE=quay.io/fedora/fedora:44
FROM ${BASE_IMAGE}
```

The image is self-contained so a fresh CI runner can build it without any
locally prepared base image. It installs the build tools plus the GTK4,
libadwaita, GLib, Pango, Cairo, font, icon and AppImage assembly packages that
Junction needs.

Junction-specific packages:

| Package | Purpose |
|---|---|
| `gjs` | runs the prebuilt `gjspack` generator and is the runtime interpreter |
| `blueprint-compiler` | compiles `src/*.blp` into `.ui` resources |
| `libportal` | provides the `Xdp-1.0` typelib |
| `libportal-gtk4` | provides the `XdpGtk4-1.0` typelib |
| `dconf` | provides `libdconfsettings.so` for persistent GSettings |

The build image keeps `LC_ALL=C.UTF-8` for stable string handling.

---

## 6. Build sequence inside the container (`inner-build.sh`)

Stages, in order:

1. `build_app`
2. `patch_paths`
3. `bundle_gjs`
4. `bundle_data`
5. `bundle_elf`
6. `install_metadata`
7. `make_appimage`

### 6.1 Build and install Junction (`build_app`)

```bash
meson setup "$BUILD" "$SRC" --prefix=/usr --buildtype=release
ninja -C "$BUILD"
DESTDIR="$APPDIR" ninja -C "$BUILD" install
```

The build directory and AppDir are wiped at the start of the run so no stale
resources survive.

### 6.2 Relocate installed paths (`patch_paths` / `patch-config.py`)

Meson's GJS launcher (`usr/bin/re.sonny.Junction`) contains absolute values:

```js
imports.package.init({
  prefix: "/usr",
  libdir: "/usr/lib64",
  datadir: "/usr/share",
});
```

`patch-config.py` rewrites each of these to:

```js
(GLib.getenv("APPDIR") || "") + "/usr..."
```

It also:

- changes the `usr/bin/junction` wrapper shebang from
  `#!/usr/bin/env bash` to `#!/bin/sh`, so it does not depend on bash on the
  host;
- sets `DBusActivatable=false` in the desktop file, because the AppImage is
  launched directly and does not ship a D-Bus `.service` file (GApplication
  still provides single-instance forwarding over the session bus).

The D-Bus activation service file installed by Meson is deleted from the
AppDir.

### 6.3 GJS runtime (`bundle_gjs`)

- `usr/bin/gjs` is copied into the bundle.
- `libgjs.so*` is copied early so the runtime can be tested before the ELF
  closure stage (it is also picked up later by the closure walker).
- GJS's private GObject-Introspection bindings
  (`GjsPrivate-1.0.typelib`) are installed in three places:
  - `usr/lib64/gjs/girepository-1.0/`
  - `usr/lib64/girepository-1.0/`
  - `usr/lib64/re.sonny.Junction/girepository-1.0/`

The third location mirrors the package-private typelib directory that
`pkg.init()` prepends (`libdir + app id`), so the private typelib resolves both
via `GI_TYPELIB_PATH` and via GJS's package-private lookup.

### 6.4 GJS private typelib relocation (`patch_gjs`)

GJS hardcodes its private typelib directory as `/usr/lib64/gjs`. On a host that
also has GJS installed, that host path could win over the bundled copy.
`patch_gjs` replaces the equal-length string in every bundled `libgjs.so*`:

```
/usr/lib64/gjs   ->   /tmp/.junction
```

`AppRun` points `/tmp/.junction` at the bundled `usr/lib64/gjs` directory for
the current mount.

### 6.5 GObject/GTK data (`bundle_data`)

Bundled:

- **GIR typelibs** — the exact transitive closure needed by the app:
  `GLib-2.0`, `GObject-2.0`, `Gio-2.0`, `GioUnix-2.0`, `GModule-2.0`,
  `Gtk-4.0`, `Gdk-4.0`, `Gsk-4.0`, `GdkPixbuf-2.0`, `Adw-1`, `Xdp-1.0`,
  `XdpGtk4-1.0`, `Pango-1.0`, `PangoCairo-1.0`, `cairo-1.0`,
  `Graphene-1.0`, `HarfBuzz-0.0`, `freetype2-2.0`, `GIRepository-3.0`.
- **GSettings schemas** — copied and recompiled with `glib-compile-schemas`.
- **Icons** — `hicolor`, `Adwaita`, `Adwaita-dark`; the large `cursors`
  subtree is removed because cursors come from the host.
- **GdkPixbuf loaders** — the directory is copied only if the distribution
  ships loader modules. gdk-pixbuf 2.44 has built-in loaders and ships none, in
  which case this is intentionally a no-op.
- **GIO modules** — only `libdconfsettings.so`, which is what persistent
  GSettings needs. TLS/proxy modules and their dependency closures are
  deliberately excluded.
- **GTK 4 modules**.
- **Translations** — only `re.sonny.Junction.mo`.

`copy_tree` copies the *contents* of directories (`cp -a src/. dst/`) rather
than nesting. This avoids the duplicate `hicolor/hicolor` tree that appeared in
an earlier AppDir.

### 6.6 ELF closure and RPATHs (`bundle_elf`)

`bundle-libs.py` walks every ELF executable/shared object in the AppDir and
copies its recursive `ldd` closure into `$APPDIR/usr/lib`.

Because GJS loads most of its dependencies through GObject-Introspection at
runtime, the script adds explicit GI seed libraries that do not appear in
`ldd` of the `gjs` executable:

```
libgtk-4.so, libadwaita-1.so, libportal.so, libportal-gtk4.so,
libgirepository-1.0.so, libgirepository-2.0.so, libcairo.so,
libcairo-gobject.so, libgdk_pixbuf-2.0.so, libgraphene-1.0.so,
libpango-1.0.so, libpangocairo-1.0.so, libpangoft2-1.0.so,
libharfbuzz.so, libglib-2.0.so, libgio-2.0.so, libgobject-2.0.so,
libgmodule-2.0.so, libgthread-2.0.so
```

The blacklist ensures host-critical libraries are never copied:

```
libc.*  libm.*  libpthread.*  libdl.*  librt.*  libresolv.*
libnss_*  libutil.*  libanl.*  libBrokenLocale.*  libmvec.*
ld-linux*  linux-vdso*  libc_malloc_debug
```

`set_rpaths` gives every dynamic executable/shared object outside `usr/lib` an
`$ORIGIN`-relative RPATH to both `usr/lib` and `usr/lib64`. Objects already in
the flat `usr/lib` directory are skipped; they resolve each other through
`$ORIGIN` and `LD_LIBRARY_PATH`.

### 6.7 Metadata and packaging

`install_metadata`:

- copies `re.sonny.Junction.desktop` to the AppDir root;
- copies the SVG icon and rasterizes a 256×256 PNG with `rsvg-convert`
  (ImageMagick fallback);
- creates `.DirIcon` as a symlink to the PNG;
- installs `packaging/AppRun`.

`make_appimage`:

- reads the version from `meson.build`;
- writes `Junction-<version>-fedora44-x86_64.AppImage`;
- uses zstd level 19. Level 22 saves under 10 KB on this image, so 19 is the
  chosen default.

---

## 7. Runtime design (`AppRun`)

`AppRun` resolves the mount from its own real path and exports:

- `PATH` with `$APPDIR/usr/bin` first
- `LD_LIBRARY_PATH` with `usr/lib` and `usr/lib64`
- `GI_TYPELIB_PATH`
- `GSETTINGS_SCHEMA_DIR`
- `XDG_DATA_DIRS` (keeping host entries after `$APPDIR`, because Junction adds
  Flatpak/Snap export paths itself)
- `GIO_MODULE_DIR`
- `GTK_PATH`

### 7.1 Fixed GJS symlink

`libgjs` was patched to use `/tmp/.junction`. `AppRun` creates:

```
/tmp/.junction -> $APPDIR/usr/lib64/gjs
```

with the same ownership guard used by the other AppImages: an existing
non-symlink or a symlink owned by another user causes a clear failure instead
of silently redirecting the application.

### 7.2 GdkPixbuf loader cache

If loader modules exist, `AppRun` generates a per-mount loader cache under the
user cache directory, keyed by a checksum of the mount path, and exports
`GDK_PIXBUF_MODULE_FILE`. With gdk-pixbuf 2.44 this normally does nothing.

### 7.3 Self-test

`AppRun --junction-self-test` writes a temporary ES module that:

1. Imports the GI namespaces used by Junction: `Gio`, `GLib`, `Gtk` 4.0,
   `Adw`, `Gdk`, `GioUnix`, `Xdp`, `XdpGtk4`.
2. Calls `imports.package.init()` with the bundled prefix/libdir/datadir.
3. Imports `resource:///re/sonny/Junction/main.js`.

This verifies the typelib set, the compiled GResource, and the GJS runtime in
one step. It runs without a display.

---

## 8. Testing

### 8.1 Clean-container test

```bash
packaging/test-appimage.sh dist/Junction-*-fedora44-x86_64.AppImage
```

This runs the AppImage in a pristine `quay.io/fedora/fedora:44` container with
no GTK/GJS packages installed, using `APPIMAGE_EXTRACT_AND_RUN=1`, and executes
`--junction-self-test`.

### 8.2 GUI smoke test on the host

```bash
dbus-run-session -- timeout 15s ./dist/Junction-*-fedora44-x86_64.AppImage
```

`dbus-run-session` isolates the test from any running Junction instance.

---

## 9. What is bundled, and what is not

Bundled:

- GJS + SpiderMonkey (`gjs`, `libgjs.so*`, `libmozjs-*.so`)
- GTK4/Gdk/Gsk, libadwaita, libportal, libportal-gtk4
- GLib/GIO/GObject/GModule/GThread
- Pango, Cairo, HarfBuzz, fontconfig, freetype, graphene
- GdkPixbuf (built-in loaders), Wayland/X11 client libraries
- `libdconfsettings.so` (the GIO settings backend module)
- Selected typelibs and the GjsPrivate typelib
- App + desktop schemas, hicolor and Adwaita icons

Not bundled:

- glibc, `ld-linux`, `libnss_*` and other host-critical libraries
- Mesa/Vulkan drivers, fonts, cursors
- Python, WebKitGTK, GtkSourceView, libspelling
- TLS/proxy GIO modules and their closures
- Flatpak/Snap runtimes (the launcher only adds their export paths if present)

---

## 10. Problems encountered and how the final build solves them

- **Duplicated icon tree (`hicolor/hicolor`)** — caused by `cp -a src dst`
  nesting when `dst` existed. `copy_tree` now copies contents explicitly.
- **Host GJS could supply a mismatched GjsPrivate typelib** — patch `libgjs`
  to use `/tmp/.junction`, and ship the typelib in the normal, private and
  package-private locations.
- **`DBusActivatable=true` without a service file** — set it to `false` and
  remove the installed `.service` file.
- **Persistent settings** — bundle `libdconfsettings.so` (and its closure) so
  GSettings behaves like a native install.
- **Missing GObject-Introspection dependencies** — add explicit GI seed
  libraries to the ELF closure walker.
- **`/bin/sh` availability** — rewrite the Junction wrapper's bash shebang to
  POSIX `sh`.

---

## 11. Final artifact

```
dist/Junction-1.13-fedora44-x86_64.AppImage
Size:   ~54 MB
Format: AppImage type 2, SquashFS + zstd level 19
```

Verified on Fedora 44: clean-container self-test passes, and the GUI starts and
stays running under an isolated session bus.
