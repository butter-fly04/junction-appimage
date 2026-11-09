# Junction AppImage (Fedora 44)

Reproducible, self-contained AppImage build for
[Junction](https://flathub.org/apps/re.sonny.Junction) 1.13, driven from the
host with rootless Podman.  The host is never modified.

The image bundles GJS + SpiderMonkey, GTK4, libadwaita, libportal/libportal-gtk4,
the required GObject-Introspection typelibs, GSettings schemas, the Adwaita icon
theme, the GdkPixbuf loaders and the dconf GIO module.  It deliberately does
**not** bundle glibc, the ELF loader or the NSS libraries; those come from the
host.

See [BUILD-PROCESS.md](BUILD-PROCESS.md) for the complete end-to-end build
recipe, including every container stage and the issues that shaped it.

## Build

```bash
./build.sh fedora44
```

The build image is self-contained and starts from `quay.io/fedora/fedora:44`.
Set `BASE_IMAGE` to reuse another Fedora 44 image (for example a local build
base), and `JUNCTION_TAG` to build a different upstream release:

```bash
JUNCTION_TAG=v1.12 ./build.sh fedora44
```

The default tag is `v1.13`. Use `FORCE_IMAGE=1 ./build.sh fedora44` to rebuild
the Podman image when the `Containerfile` changes.

Artifact: `dist/Junction-1.13-fedora44-x86_64.AppImage` (about 54 MB).

The output uses zstd level 19.  Override the level with
`APPIMAGE_COMPRESS_LEVEL=<1-22>` if needed; the bundled `appimagetool` supports
only zstd.  Level 22 saves under 10 KB on this image, so 19 is the default.

## GitHub Actions

`.github/workflows/build.yml` runs on every push to `main`, weekly on a
schedule, and on demand. It resolves the newest Junction tag, builds the
AppImage in rootless Podman, smoke-tests it in clean Fedora 44 and Ubuntu 26.04
containers, and publishes the AppImage plus its SHA-256 as a GitHub release
tagged with the upstream tag. Scheduled runs skip tags that already have a
release.

Use **Actions → Build Junction AppImage → Run workflow** to build a specific
tag or force a rebuild.

The workflow installs Podman on the disposable GitHub runner only. Local builds
still use your existing rootless Podman and do not modify the host.

## Test

Clean container (no GTK/GJS/packages installed):

```bash
packaging/test-appimage.sh dist/Junction-*.AppImage

# Minimum supported target
TEST_IMAGE=ubuntu:26.04 packaging/test-appimage.sh dist/Junction-*.AppImage
```

GUI smoke test on the host, isolated from any running instance:

```bash
dbus-run-session -- timeout 15s ./dist/Junction-*.AppImage
```

## Layout inside the AppImage

```
AppRun                                  environment + self-test
usr/bin/gjs                             GJS runtime
usr/bin/junction                        launcher wrapper (/bin/sh)
usr/bin/re.sonny.Junction               GJS entry point (patched for $APPDIR)
usr/share/re.sonny.Junction/*.gresource compiled GJS application
usr/share/glib-2.0/schemas              app + desktop schemas
usr/share/icons/hicolor                 application icons
usr/share/icons/Adwaita                 symbolic UI icons (cursors trimmed)
usr/lib64/girepository-1.0              selected typelibs
usr/lib64/gdk-pixbuf-2.0                loaders (cache generated at runtime)
usr/lib64/gio/modules/libdconfsettings.so
usr/lib                                 bundled ELF closure
```

## Notes

- The desktop file is shipped with `DBusActivatable=false` because the AppImage
  has no D-Bus `.service` file; GApplication still provides single-instance
  forwarding over the session bus.
- `junction` appends Flatpak and Snap export paths to `XDG_DATA_DIRS`, which is
  why the bundled `XDG_DATA_DIRS` keeps the host entries after `$APPDIR`.
- The `bundle-libs.py` closure never copies `libc`, `ld-linux`, `libnss_*` or
  the other host-critical libraries.
- Upstream hardcodes `re.sonny.Junction.desktop` when it calls `gio mime`.
  Integration tools such as Gear Lever name the desktop file after the AppImage
  (`junction.appimage` → `junction.desktop`), so the hardcoded id names no file
  and links fall back to the previous browser on every Junction start.
  `packaging/patch-desktop-id.py` resolves the entry that launches `$APPIMAGE`
  at runtime and keeps the upstream id only as a fallback.
