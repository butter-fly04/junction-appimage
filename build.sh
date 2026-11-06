#!/usr/bin/env bash
# Host-side driver. All builds happen in a rootless Podman container.
#
# The CI workflow calls this script with JUNCTION_TAG set to the newest
# upstream tag and caches tools/ between runs. It can be run locally without
# any CI-specific environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="${1:-fedora44}"
JUNCTION_TAG="${JUNCTION_TAG:-v1.13}"
BASE_IMAGE="${BASE_IMAGE:-quay.io/fedora/fedora:44}"

case "$DISTRO" in
  fedora44)
    BUILD_IMAGE="${BUILD_IMAGE:-localhost/junction-build:fedora44}"
    CONTAINERFILE="$ROOT/packaging/Containerfile.fedora44"
    ;;
  *)
    echo "usage: $0 [fedora44]" >&2
    exit 2
    ;;
esac

SRC="$ROOT/src"
WORK="$ROOT/work/$DISTRO"
SRCCOPY="$WORK/src"
OUT="$ROOT/dist"
TOOLS="$ROOT/tools"

# ---------------------------------------------------------------------------
# Source checkout
# ---------------------------------------------------------------------------
current=""
if [ -d "$SRC/.git" ]; then
  current="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
elif [ -e "$SRC" ]; then
  echo "==> Removing non-git source directory $SRC"
  rm -rf "$SRC"
fi

if [ -d "$SRC/.git" ] && [ -n "$JUNCTION_TAG" ] && [ "$current" != "$JUNCTION_TAG" ]; then
  echo "==> Existing checkout is ${current:-not an exact tag}; re-cloning $JUNCTION_TAG"
  rm -rf "$SRC"
fi

if [ ! -d "$SRC/.git" ]; then
  echo "==> Cloning Junction ${JUNCTION_TAG:-default branch}"
  if [ -n "$JUNCTION_TAG" ]; then
    git clone --depth 1 --branch "$JUNCTION_TAG" \
      https://github.com/sonnyp/Junction.git "$SRC"
  else
    git clone --depth 1 \
      https://github.com/sonnyp/Junction.git "$SRC"
  fi
else
  echo "==> Reusing existing checkout at $SRC (${current:-not an exact tag})"
fi

if [ ! -f "$SRC/troll/gjspack/bin/gjspack" ]; then
  echo "==> Initializing troll submodule"
  git -C "$SRC" submodule update --init --recursive
fi

mkdir -p "$WORK" "$OUT" "$TOOLS"

# ---------------------------------------------------------------------------
# AppImage tooling
# ---------------------------------------------------------------------------
TOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -s "$TOOL" ]; then
  echo "==> Downloading appimagetool"
  curl -fL --retry 3 -o "$TOOL" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$TOOL"
fi

RUNTIME="$TOOLS/runtime-x86_64"
if [ ! -s "$RUNTIME" ]; then
  echo "==> Downloading AppImage runtime"
  curl -fL --retry 5 --retry-delay 3 -o "$RUNTIME" \
    "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"
  chmod +x "$RUNTIME"
fi

# Keep the pristine checkout; build from a disposable copy so generated files
# from one run never leak into the next.
rm -rf "$SRCCOPY"
cp -a "$SRC" "$SRCCOPY"
rm -rf "$SRCCOPY/.git" "$SRCCOPY/troll/.git"

# ---------------------------------------------------------------------------
# Build image
# ---------------------------------------------------------------------------
if [ "${FORCE_IMAGE:-0}" != "1" ] && podman image exists "$BUILD_IMAGE"; then
  echo "==> Reusing build image $BUILD_IMAGE (FORCE_IMAGE=1 to rebuild)"
else
  echo "==> Creating build image $BUILD_IMAGE from $BASE_IMAGE"
  podman build --network=host \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$BUILD_IMAGE" -f "$CONTAINERFILE" "$ROOT/packaging"
fi

# ---------------------------------------------------------------------------
# Container build
# ---------------------------------------------------------------------------
echo "==> Building in $BUILD_IMAGE"
podman run --rm \
  --network=host \
  --security-opt label=disable \
  -v "$ROOT:/work:Z" \
  -e DISTRO="$DISTRO" \
  -e NAME="$DISTRO" \
  -e SRC="/work/work/$DISTRO/src" \
  -e WORK="/work/work/$DISTRO" \
  -e OUT="/work/dist" \
  -e PACKAGING="/work/packaging" \
  -e TOOLS="/work/tools" \
  "$BUILD_IMAGE" \
  /bin/bash "/work/packaging/inner-build.sh"

echo "==> Done. Artifacts:"
ls -lh "$OUT"
