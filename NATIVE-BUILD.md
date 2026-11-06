# Native dependency map (Fedora 44)

This is the minimal runtime set that ends up in the Junction AppImage.  It is
documented here so the bundle can be audited without unpacking the image.

## Build-time (container only)

| Package | Why |
|---|---|
| `gjs` | runs `troll/gjspack/bin/gjspack` and is the runtime interpreter |
| `blueprint-compiler` | compiles `src/*.blp` into `.ui` resources |
| `libportal`, `libportal-gtk4` | provide the `Xdp-1.0` and `XdpGtk4-1.0` typelibs |
| `meson`, `ninja`, `gcc` | build system (installed by `Containerfile.fedora44`) |
| `gtk4-devel`, `libadwaita-devel` | headers used by the distro packages |
| `librsvg2-tools` | renders the 256×256 PNG `.DirIcon` |
| `patchelf` | rewrites RPATHs |
| `dconf` | provides `libdconfsettings.so` |

## Runtime (bundled)

| Component | Source |
|---|---|
| GJS + SpiderMonkey | `/usr/bin/gjs`, `libgjs.so*`, `libmozjs-*.so` |
| GTK4 / Gdk / Gsk | `libgtk-4.so*`, `libgdk-*.so` |
| libadwaita | `libadwaita-1.so*` |
| libportal / libportal-gtk4 | `libportal.so*`, `libportal-gtk4.so*` |
| GLib stack | `libglib-2.0`, `libgio-2.0`, `libgobject-2.0`, `libgmodule-2.0` |
| text/rendering | Pango, cairo, HarfBuzz, fontconfig, freetype, graphene |
| image loading | `libgdk_pixbuf-2.0` (gdk-pixbuf 2.44 has built-in loaders) |
| Wayland/X11 | `libwayland-*`, `libX11`, `libxkbcommon`, etc. (ELF closure) |
| settings | `libdconfsettings.so` + `libdconf.so` |
| typelibs | GLib, Gio, GioUnix, Gtk, Gdk, Gsk, GdkPixbuf, Adw, Xdp, XdpGtk4, Pango, cairo, Graphene, HarfBuzz, freetype2, GIRepository |
| GJS private typelib | `GjsPrivate-1.0` (redirected through `/tmp/.junction`) |
| schemas | app schema + `gsettings-desktop-schemas` |
| icons | hicolor application icons + Adwaita symbolic icons |

## Deliberately not bundled

- glibc, `ld-linux`, `libnss_*` and the other host-critical libraries
- Python, WebKitGTK, GtkSourceView, libspelling (not used by Junction)
- TLS/proxy GIO modules (`libgiognutls`, `libgiognomeproxy`) and their closures
- Mesa drivers, Vulkan, fonts and cursors (provided by the host)
- Flatpak/Snap runtimes: the wrapper only adds their export directories to
  `XDG_DATA_DIRS` when they exist
