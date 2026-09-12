#!/usr/bin/env bash
#
# Container side of scripts/docker/build.sh: configure, build, verify and
# package the requested targets, one build tree per target.
#
#   bash scripts/docker/container-build.sh [linux] [linux-arm64] [windows] [all]
#
# It expects the toolchains the Dockerfile lays out (the MinGW and aarch64
# OpenSSL prefixes) but locates them through environment variables, so it also
# runs on an Ubuntu host with the same packages installed. Everything is driven
# by environment variables; see scripts/docker/README.md for the list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build-docker}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/builds}"
JOBS="${JOBS:-}"
VERSION="${VERSION:-}"
CLEAN="${CLEAN:-0}"
KEEP_GOING="${KEEP_GOING:-0}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
GENERATOR="${GENERATOR:-Ninja}"

MINGW_TRIPLE="${MINGW_PREFIX:-x86_64-w64-mingw32}"
MINGW_PREFIX_DIR="${DEROGOLD_MINGW_PREFIX_DIR:-$HOME/toolchain/windows-x86_64/prefix}"

ARM64_TRIPLE="${ARM64_TRIPLE:-aarch64-linux-gnu}"
ARM64_PREFIX_DIR="${DEROGOLD_ARM64_PREFIX_DIR:-$HOME/toolchain/linux-arm64/prefix}"

# Executables a package can carry (plus LICENSE). Each one is packaged only if
# the checked-out src/CMakeLists.txt declares it, so the same script serves a
# branch with or without the newer targets. A declared executable that is
# missing after the build is still an error.
BINARY_CANDIDATES=(
  DeroGoldd
  degwallet
  DeroGold-service
  wallet-api
  degwallet-upgrader
  miner
  cryptotest
  DeroGold-txpow-server
)
BINARIES=()
PKG_PREFIX="${PKG_PREFIX:-derogold-cli}"

# Packages written by this run, recorded through a file because run_target
# executes each target in a pipeline (and therefore a subshell).
PACKAGE_LIST="$BUILD_ROOT/packages.list"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# x.y.z.b from project(DeroGold VERSION ...) in the root CMakeLists.txt, which
# is where this tree keeps the number - src/config/version.h.in only holds the
# CMake placeholders that are substituted into it.
read_version() {
  local v
  v="$(sed -n 's/^[[:space:]]*project(DeroGold[[:space:]]\+VERSION[[:space:]]\+\([0-9.]\+\).*/\1/p' \
        "$REPO_ROOT/CMakeLists.txt" | head -1 | tr -d '\r')"
  [ -n "$v" ] || die "cannot read the version from project() in $REPO_ROOT/CMakeLists.txt"
  printf '%s' "$v"
}

# Fill BINARIES with the candidates this checkout actually builds.
resolve_binaries() {
  local cml="$REPO_ROOT/src/CMakeLists.txt" b
  BINARIES=()
  for b in "${BINARY_CANDIDATES[@]}"; do
    if grep -q "OUTPUT_NAME \"$b\"" "$cml"; then
      BINARIES+=("$b")
    else
      echo "note: $b is not a target in this checkout; not packaged"
    fi
  done
  [ "${#BINARIES[@]}" -gt 0 ] || die "no packageable executables declared in $cml"
}

# configure_and_build <build-dir> [cmake configure args...]
configure_and_build() {
  local bd="$1"
  shift
  if [ "$CLEAN" = "1" ] && [ -d "$bd" ]; then
    log "CLEAN=1: removing $bd"
    rm -rf "$bd"
  fi
  mkdir -p "$bd"
  log "Configuring $bd"
  cmake -S "$REPO_ROOT" -B "$bd" \
    -G "$GENERATOR" \
    -D CMAKE_BUILD_TYPE="$BUILD_TYPE" \
    "$@"
  log "Building $bd with $JOBS jobs"
  cmake --build "$bd" --parallel "$JOBS"
}

# stage_dir <package-name>: fresh staging directory, path on stdout.
stage_dir() {
  local d="$BUILD_ROOT/pkg/$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s' "$d"
}

# stage_binaries <bin-dir> <stage-dir> <suffix>: copy the executables and the
# root LICENSE into the staging directory. A missing executable is an error;
# a package with a binary silently left out is worse than no package.
stage_binaries() {
  local bindir="$1" stage="$2" suffix="$3" b
  for b in "${BINARIES[@]}"; do
    [ -f "$bindir/$b$suffix" ] || die "missing binary: $bindir/$b$suffix"
    cp "$bindir/$b$suffix" "$stage/"
    chmod 755 "$stage/$b$suffix"
  done
  cp "$REPO_ROOT/LICENSE" "$stage/LICENSE"
}

# record_package <path>: remember a package this run produced, so the summary
# can checksum it even though each target runs in its own subshell.
record_package() {
  printf '%s\n' "$1" >> "$PACKAGE_LIST"
}

# make_tarball <package-name>
make_tarball() {
  local name="$1" out="$OUT_DIR/$1.tar.gz"
  rm -f "$out"
  tar -C "$BUILD_ROOT/pkg" --owner=0 --group=0 --numeric-owner -czf "$out" "$name"
  record_package "$out"
  log "Package: $out"
}

# make_zip <package-name>
make_zip() {
  local name="$1" out="$OUT_DIR/$1.zip"
  rm -f "$out"
  (cd "$BUILD_ROOT/pkg" && zip -q -r -X "$out" "$name")
  record_package "$out"
  log "Package: $out"
}

# print_files <stage-dir> <suffix>: 'file' output for every executable.
print_files() {
  local stage="$1" suffix="$2" b
  for b in "${BINARIES[@]}"; do
    file "$stage/$b$suffix"
  done
}

# find_mingw_dll <name>: path of a MinGW runtime DLL on this host.
find_mingw_dll() {
  local dll="$1" cc p d
  for cc in "$MINGW_TRIPLE-g++-posix" "$MINGW_TRIPLE-g++" "$MINGW_TRIPLE-gcc-posix" "$MINGW_TRIPLE-gcc"; do
    command -v "$cc" >/dev/null 2>&1 || continue
    p="$("$cc" -print-file-name="$dll" 2>/dev/null || true)"
    if [ -n "$p" ] && [ "$p" != "$dll" ] && [ -f "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  for d in "/usr/$MINGW_TRIPLE/lib" "/usr/$MINGW_TRIPLE/bin" \
           /usr/lib/gcc/"$MINGW_TRIPLE"/*-posix /usr/lib/gcc/"$MINGW_TRIPLE"/*; do
    if [ -f "$d/$dll" ]; then
      printf '%s' "$d/$dll"
      return 0
    fi
  done
  return 1
}

# bundle_mingw_dlls <stage-dir>: copy every MinGW runtime DLL the executables
# actually import next to them. This tree links MinGW builds with -static (see
# the MINGW branch in the root CMakeLists.txt), so normally there are none and
# this reports that; it stays because a link flag change would otherwise
# produce a zip that fails to start on a machine without MSYS2. Imports that do
# not start with "lib" are Windows system DLLs and are left alone.
bundle_mingw_dlls() {
  local stage="$1" exe dll lower path
  local -A wanted=()
  for exe in "$stage"/*.exe; do
    while read -r dll; do
      [ -n "$dll" ] || continue
      lower="$(printf '%s' "$dll" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in
        lib*.dll) wanted["$dll"]=1 ;;
      esac
    done < <("$MINGW_TRIPLE-objdump" -p "$exe" | awk '/DLL Name:/ { print $3 }')
  done
  if [ "${#wanted[@]}" -eq 0 ]; then
    echo "No MinGW runtime DLLs are imported; the executables are self-contained."
    return 0
  fi
  for dll in "${!wanted[@]}"; do
    path="$(find_mingw_dll "$dll")" \
      || die "$dll is imported by the Windows executables but was not found on this host"
    cp "$path" "$stage/"
    echo "Bundled runtime DLL: $dll  ($path)"
  done
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

build_linux() {
  local bd="$BUILD_ROOT/linux-x86_64"
  local name="$PKG_PREFIX-linux-x86_64-$VERSION"

  # ARCH=default is the CPU question (no -march, so the binary runs on any
  # x86-64); -static plus OPENSSL_USE_STATIC_LIBS is the loader question, and
  # together they remove the glibc floor that BUILDING.md describes. glibc's
  # name lookups then use the 'files' and 'dns' backends built into libc,
  # which is what every mainstream distribution ships.
  configure_and_build "$bd" \
    -D ARCH=default \
    -D SET_COMMIT_ID_IN_VERSION=OFF \
    -D OPENSSL_USE_STATIC_LIBS=ON \
    -D CMAKE_EXE_LINKER_FLAGS="-static"

  local stage b
  stage="$(stage_dir "$name")"
  stage_binaries "$bd/src" "$stage" ""

  log "Verifying Linux executables"
  print_files "$stage" ""
  for b in "${BINARIES[@]}"; do
    file "$stage/$b" | grep -q 'statically linked' \
      || die "$b is not statically linked"
  done
  # The build host is x86_64 Linux, so the daemon and wallet can prove they
  # start. Run from the staging directory so any log file lands there.
  (cd "$stage" && ./DeroGoldd --version && ./degwallet --version)
  rm -f "$stage"/*.log

  make_tarball "$name"
}

build_windows() {
  local bd="$BUILD_ROOT/windows-x86_64"
  local name="$PKG_PREFIX-windows-x86_64-$VERSION"
  [ -f "$MINGW_PREFIX_DIR/lib/libcrypto.a" ] \
    || die "no Windows-target OpenSSL under $MINGW_PREFIX_DIR (DEROGOLD_MINGW_PREFIX_DIR)"
  command -v "$MINGW_TRIPLE-g++-posix" >/dev/null 2>&1 || command -v "$MINGW_TRIPLE-g++" >/dev/null 2>&1 \
    || die "MinGW-w64 compiler $MINGW_TRIPLE-g++ not found"

  # CMake/windows-x64-mingw-cross.cmake reads CROSS_PREFIX; FindOpenSSL reads
  # OPENSSL_ROOT_DIR. The host's OpenSSL cannot be linked into a Windows
  # binary, so both have to point at the prefix built for the target.
  export CROSS_PREFIX="$MINGW_PREFIX_DIR"
  export OPENSSL_ROOT_DIR="$MINGW_PREFIX_DIR"
  export CMAKE_PREFIX_PATH="$MINGW_PREFIX_DIR"

  configure_and_build "$bd" \
    -D CMAKE_TOOLCHAIN_FILE="$REPO_ROOT/CMake/windows-x64-mingw-cross.cmake" \
    -D ARCH=default \
    -D SET_COMMIT_ID_IN_VERSION=OFF \
    -D OPENSSL_USE_STATIC_LIBS=ON

  local stage b
  stage="$(stage_dir "$name")"
  stage_binaries "$bd/src" "$stage" ".exe"

  log "Stripping and verifying Windows executables"
  for b in "${BINARIES[@]}"; do
    "$MINGW_TRIPLE-strip" "$stage/$b.exe"
  done
  print_files "$stage" ".exe"
  for b in "${BINARIES[@]}"; do
    file "$stage/$b.exe" | grep -q 'x86-64' \
      || die "$b.exe is not an x86-64 PE executable"
  done
  bundle_mingw_dlls "$stage"

  make_zip "$name"
}

build_linux_arm64() {
  local bd="$BUILD_ROOT/linux-arm64"
  local name="$PKG_PREFIX-linux-arm64-$VERSION"
  [ -f "$ARM64_PREFIX_DIR/lib/libcrypto.a" ] \
    || die "no ARM64-target OpenSSL under $ARM64_PREFIX_DIR (DEROGOLD_ARM64_PREFIX_DIR)"
  command -v "$ARM64_TRIPLE-g++" >/dev/null 2>&1 \
    || die "aarch64 cross compiler $ARM64_TRIPLE-g++ not found (crossbuild-essential-arm64)"

  # CMake/linux-arm64-gcc.cmake names the compilers and sets the find modes to
  # ONLY, but leaves CMAKE_FIND_ROOT_PATH empty - so the roots to search have to
  # come from here, or FindOpenSSL has nowhere to look. The host's OpenSSL is
  # x86_64 and must not be found.
  export OPENSSL_ROOT_DIR="$ARM64_PREFIX_DIR"
  export CMAKE_PREFIX_PATH="$ARM64_PREFIX_DIR"

  configure_and_build "$bd" \
    -D CMAKE_TOOLCHAIN_FILE="$REPO_ROOT/CMake/linux-arm64-gcc.cmake" \
    -D CMAKE_FIND_ROOT_PATH="$ARM64_PREFIX_DIR;/usr/$ARM64_TRIPLE" \
    -D ARCH=default \
    -D SET_COMMIT_ID_IN_VERSION=OFF \
    -D OPENSSL_USE_STATIC_LIBS=ON \
    -D CMAKE_EXE_LINKER_FLAGS="-static"

  local stage b
  stage="$(stage_dir "$name")"
  stage_binaries "$bd/src" "$stage" ""

  log "Stripping and verifying Linux ARM64 executables"
  for b in "${BINARIES[@]}"; do
    "$ARM64_TRIPLE-strip" "$stage/$b"
  done
  print_files "$stage" ""
  for b in "${BINARIES[@]}"; do
    file "$stage/$b" | grep -q 'aarch64' \
      || die "$b is not an aarch64 executable"
    file "$stage/$b" | grep -q 'statically linked' \
      || die "$b is not statically linked"
  done
  # No --version smoke test here: nothing in this container executes aarch64.

  make_tarball "$name"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

run_target() {
  local target="$1"
  local logfile="$BUILD_ROOT/logs/$target.log"
  mkdir -p "$BUILD_ROOT/logs"
  log "Target: $target  (log: $logfile)"
  # linux-arm64 -> build_linux_arm64: a hyphen is legal in a bash function
  # name but not worth relying on.
  if "build_${target//-/_}" 2>&1 | tee "$logfile"; then
    return 0
  fi
  # The build ran in a pipeline, so consult its status rather than $?.
  return "${PIPESTATUS[0]}"
}

main() {
  local requested=("$@") targets=() t failed=()

  for t in "${requested[@]}"; do
    case "$t" in
      all) targets+=(linux linux-arm64 windows) ;;
      linux|linux-arm64|windows) targets+=("$t") ;;
      *) die "unknown target: $t" ;;
    esac
  done
  # Deduplicate while keeping order, so "all linux" does not build linux twice.
  local unique=()
  for t in ${targets[@]+"${targets[@]}"}; do
    case " ${unique[*]} " in
      *" $t "*) ;;
      *) unique+=("$t") ;;
    esac
  done
  targets=(${unique[@]+"${unique[@]}"})

  [ -n "$JOBS" ] || JOBS="$(nproc)"
  [ -n "$VERSION" ] || VERSION="$(read_version)"

  mkdir -p "$OUT_DIR" "$BUILD_ROOT"
  rm -f "$PACKAGE_LIST"

  resolve_binaries

  echo "DeroGold $VERSION"
  echo "  targets:  ${targets[*]}"
  echo "  binaries: ${BINARIES[*]}"
  echo "  jobs:     $JOBS"
  echo "  build:    $BUILD_ROOT"
  echo "  output:   $OUT_DIR"

  for t in "${targets[@]}"; do
    if ! run_target "$t"; then
      if [ "$KEEP_GOING" = "1" ]; then
        failed+=("$t")
        echo "warning: target $t failed; continuing because KEEP_GOING=1" >&2
        continue
      fi
      die "target $t failed (see $BUILD_ROOT/logs/$t.log)"
    fi
  done

  if [ -s "$PACKAGE_LIST" ]; then
    local sums="$OUT_DIR/SHA256SUMS-$VERSION.txt"
    log "Checksums: $sums"
    (cd "$OUT_DIR" && xargs -a "$PACKAGE_LIST" -n1 basename | xargs sha256sum) > "$sums"
    cat "$sums"
  fi

  if [ "${#failed[@]}" -gt 0 ]; then
    die "these targets failed: ${failed[*]}"
  fi

  log "Done"
}

main "$@"
