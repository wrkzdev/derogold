#!/usr/bin/env bash
#
# Build the portable DeroGold CLI release set inside Docker.
#
#   bash scripts/docker/build.sh              # linux + windows
#   bash scripts/docker/build.sh linux        # one target
#   bash scripts/docker/build.sh --shell      # interactive shell in the image
#
# Builds the toolchain image (cached after the first run), bind-mounts this
# repository into it and runs container-build.sh, which configures, builds and
# packages each target. Packages land in builds/ (see OUT_DIR) as
#
#   derogold-cli-linux-x86_64-<version>.tar.gz
#   derogold-cli-windows-x86_64-<version>.zip
#
# Full documentation: scripts/docker/README.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-derogold-builder:latest}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/builds}"
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build-docker}"
JOBS="${JOBS:-}"
VERSION="${VERSION:-}"
CLEAN="${CLEAN:-0}"
KEEP_GOING="${KEEP_GOING:-0}"
NO_IMAGE_BUILD="${NO_IMAGE_BUILD:-0}"
IMAGE_BUILD_ARGS="${IMAGE_BUILD_ARGS:-}"

usage() {
  cat <<EOF
Usage: bash scripts/docker/build.sh [options] [target ...]

Targets (default: all):
  linux        Linux x86_64, fully static     -> .tar.gz
  linux-arm64  Linux ARM64, fully static      -> .tar.gz
  windows      Windows x86_64, MinGW-w64      -> .zip
  gui          DeroGold GUI Wallet, Linux     -> .tar.gz
  web          DeroGold Web Wallet (WASM)     -> .tar.gz
  android      Android APK + AAB, release and debug
  cli          linux linux-arm64 windows
  apps         gui web android
  all          everything above

Options:
  --shell        open an interactive shell in the builder image instead
  --image-only   build/refresh the builder image and stop
  -h, --help     this text

Environment:
  JOBS=N                 parallel compile jobs (default: all container CPUs)
  VERSION=x.y.z.b        package version (default: project() in CMakeLists.txt)
  OUT_DIR=path           where packages go (default: builds/)
  BUILD_ROOT=path        build trees + ccache (default: build-docker/)
  CLEAN=1                wipe each target's build tree first
  KEEP_GOING=1           keep building other targets after a failure
  IMAGE=name:tag         image name (default: derogold-builder:latest)
  NO_IMAGE_BUILD=1       do not (re)build the image
  IMAGE_BUILD_ARGS="..." extra 'docker build' arguments, e.g.
                         "--build-arg UBUNTU_VERSION=24.04"
  DOCKER=podman          container CLI to use
  DOCKER_PLATFORM=...    image platform (default: linux/amd64)

  ANDROID_ABIS="..."     ABIs for the wallet library; must match abiFilters
                         in extras/mobile-wallet/android/app/build.gradle
                         (default: "arm64-v8a x86_64")
  MOBILE_MODES="..."     Android build modes  (default: "release debug")
  MOBILE_FORMATS="..."   Android formats      (default: "apk aab")

Not available: macos. This image has no macOS cross-toolchain, and Apple's SDK
cannot be redistributed in one. See "Other platforms" in
scripts/docker/README.md.

The gui, web and android targets need the app toolchains (Flutter, the Android
SDK/NDK, Emscripten). They are in the image, which is why it is large; the cli
targets do not use them.
EOF
}

MODE=build
TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --shell) MODE=shell ;;
    --image-only) MODE=image ;;
    linux|linux-arm64|windows|gui|web|android|cli|apps|all) TARGETS+=("$1") ;;
    macos)
      echo "The 'macos' target needs a macOS cross-toolchain this image does not carry; see 'Other platforms' in scripts/docker/README.md." >&2
      exit 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
  TARGETS=(all)
fi

if ! command -v "$DOCKER" >/dev/null 2>&1; then
  echo "'$DOCKER' is not on PATH. Install Docker (or set DOCKER=podman)." >&2
  exit 1
fi

# Git Bash / MSYS on a Windows host: hand Docker native paths and stop MSYS
# from rewriting the container-side paths in -v/-w arguments.
HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
case "$HOST_OS" in
  MINGW*|MSYS*|CYGWIN*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    host_path() { cygpath -m "$1"; }
    ;;
  *)
    host_path() { printf '%s' "$1"; }
    ;;
esac

# Run the container as the invoking user on Linux so the build tree and the
# packages are not root-owned. Under sudo, use the real user's ids.
USER_ARGS=()
if [ "$HOST_OS" = "Linux" ]; then
  uid="${SUDO_UID:-$(id -u)}"
  gid="${SUDO_GID:-$(id -g)}"
  USER_ARGS=(--user "$uid:$gid")
fi

TTY_ARGS=()
if [ -t 0 ] && [ -t 1 ]; then
  TTY_ARGS=(-it)
fi

if [ "$NO_IMAGE_BUILD" != "1" ]; then
  echo "==> Building image $IMAGE ($DOCKER_PLATFORM)"
  # shellcheck disable=SC2086  # IMAGE_BUILD_ARGS is a list of extra arguments
  "$DOCKER" build \
    --platform "$DOCKER_PLATFORM" \
    $IMAGE_BUILD_ARGS \
    -t "$IMAGE" \
    -f "$(host_path "$SCRIPT_DIR/Dockerfile")" \
    "$(host_path "$SCRIPT_DIR/..")"
fi

if [ "$MODE" = "image" ]; then
  echo "Image ready: $IMAGE"
  exit 0
fi

mkdir -p "$OUT_DIR" "$BUILD_ROOT"

RUN_ARGS=(
  run --rm
  --platform "$DOCKER_PLATFORM"
  # Empty-array-safe expansion (bash 3.2 on macOS trips on "${a[@]}" + set -u).
  ${USER_ARGS[@]+"${USER_ARGS[@]}"}
  ${TTY_ARGS[@]+"${TTY_ARGS[@]}"}
  -v "$(host_path "$REPO_ROOT"):/work"
  -v "$(host_path "$BUILD_ROOT"):/build"
  -v "$(host_path "$OUT_DIR"):/out"
  -w /work
  -e "JOBS=$JOBS"
  -e "VERSION=$VERSION"
  -e "CLEAN=$CLEAN"
  -e "KEEP_GOING=$KEEP_GOING"
  -e BUILD_ROOT=/build
  -e OUT_DIR=/out
  # The mounted checkout is normally owned by the container user already;
  # this covers Docker Desktop and root-owned checkouts.
  -e GIT_CONFIG_COUNT=1
  -e GIT_CONFIG_KEY_0=safe.directory
  -e "GIT_CONFIG_VALUE_0=*"
)

# Only forwarded when the caller set them, so the defaults stay where they are
# documented - in container-build.sh - rather than being duplicated here.
for var in ANDROID_ABIS MOBILE_MODES MOBILE_FORMATS ANDROID_API BUILD_TYPE GENERATOR PKG_PREFIX; do
  if [ -n "${!var:-}" ]; then
    RUN_ARGS+=(-e "$var=${!var}")
  fi
done

if [ "$MODE" = "shell" ]; then
  if [ "${#TTY_ARGS[@]}" -eq 0 ]; then
    echo "--shell needs an interactive terminal." >&2
    exit 1
  fi
  echo "==> Shell in $IMAGE (repo at /work, build tree at /build, packages at /out)"
  exec "$DOCKER" "${RUN_ARGS[@]}" "$IMAGE" bash
fi

echo "==> Building targets: ${TARGETS[*]}"
"$DOCKER" "${RUN_ARGS[@]}" "$IMAGE" \
  bash /work/scripts/docker/container-build.sh "${TARGETS[@]}"
