#!/usr/bin/env bash
#
# Build libucontext for Android, one static library per ABI.
#
#   bash scripts/build-libucontext-android.sh [abi ...]
#
# Why this exists
# ---------------
# The wallet's fibre dispatcher (src/platform/linux/system/) is built on
# getcontext/setcontext/makecontext/swapcontext. glibc has them; bionic does
# not, and never has - they were left out of Android's libc deliberately. So
# on Android they have to come from somewhere else, and libucontext is that
# somewhere: a small implementation of exactly those four functions.
#
# The result is what the CMake option LIBUCONTEXT_ROOT points at. Each ABI gets
# its own root, because a static library is per-architecture:
#
#   <prefix>/arm64-v8a/{include,lib/libucontext.a}
#   <prefix>/x86_64/{include,lib/libucontext.a}
#
# and a wallet build for one ABI is configured with
#
#   -D DEROGOLD_ANDROID_PROFILE=ON
#   -D LIBUCONTEXT_ROOT=<prefix>/arm64-v8a
#
# Build system
# ------------
# meson, not make. Current libucontext is a meson project; the make path only
# works on much older releases and needs the architecture named by hand.
#
# Requires: git, meson, ninja, python3.
#
# Environment
# -----------
#   ANDROID_NDK_HOME   the NDK (required; ANDROID_NDK_ROOT and ANDROID_NDK too)
#   PREFIX             where to install    (default: build-android/libucontext)
#   LIBUCONTEXT_REF    git ref to build    (default: master)
#   API                Android API level   (default: 24)
#   JOBS               parallel jobs       (default: nproc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
PREFIX="${PREFIX:-$REPO_ROOT/build-android/libucontext}"
LIBUCONTEXT_GIT_URL="${LIBUCONTEXT_GIT_URL:-https://github.com/kaniini/libucontext.git}"
LIBUCONTEXT_REF="${LIBUCONTEXT_REF:-master}"
API="${API:-24}"
JOBS="${JOBS:-$(nproc)}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

[ -n "$NDK" ] || die "set ANDROID_NDK_HOME to the Android NDK"
[ -d "$NDK" ] || die "ANDROID_NDK_HOME does not exist: $NDK"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || die "no linux-x86_64 LLVM toolchain under $NDK"

for tool in git meson ninja python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# <android-abi>:<clang-triple>:<meson cpu_family>:<meson cpu>
#
# armeabi-v7a is deliberately absent. The mobile wallet's abiFilters ships
# arm64-v8a and x86_64 only, so a 32-bit arm library would be built and then
# discarded.
ALL_ABIS=(
  "arm64-v8a:aarch64-linux-android:aarch64:aarch64"
  "x86_64:x86_64-linux-android:x86_64:x86_64"
)

# Buildable on request, just not by default.
EXTRA_ABIS=(
  "armeabi-v7a:armv7a-linux-androideabi:arm:armv7"
  "x86:i686-linux-android:x86:i686"
)

select_abis() {
  local requested=("$@") out=() want entry found
  if [ "${#requested[@]}" -eq 0 ]; then
    printf '%s\n' "${ALL_ABIS[@]}"
    return 0
  fi
  for want in "${requested[@]}"; do
    found=0
    for entry in "${ALL_ABIS[@]}" "${EXTRA_ABIS[@]}"; do
      if [ "${entry%%:*}" = "$want" ]; then
        out+=("$entry")
        found=1
        break
      fi
    done
    [ "$found" = "1" ] || die "unknown ABI: $want (known: arm64-v8a x86_64 armeabi-v7a x86)"
  done
  printf '%s\n' "${out[@]}"
}

WORK_DIR="$PREFIX/work"
SRC_DIR="$WORK_DIR/src"

fetch_source() {
  mkdir -p "$WORK_DIR"

  if [ -d "$SRC_DIR/.git" ]; then
    log "Refreshing libucontext in $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin "$LIBUCONTEXT_REF"
    git -C "$SRC_DIR" checkout -f FETCH_HEAD
  else
    log "Cloning libucontext ($LIBUCONTEXT_REF)"
    git clone --depth 1 --branch "$LIBUCONTEXT_REF" "$LIBUCONTEXT_GIT_URL" "$SRC_DIR"
  fi

  git -C "$SRC_DIR" --no-pager log -1 --format='    at %h %s' || true
}

# ---------------------------------------------------------------------------
# The one place bionic and libucontext disagree
#
# libucontext is written for musl, whose <ucontext.h> says nothing about the
# machine registers, so it supplies its own REG_* macros for x86_64. bionic
# does declare them - as enum constants in <sys/ucontext.h> - and the two
# cannot coexist: the macro expands inside the enum declaration and clang
# stops at "expected identifier".
#
# Two narrow changes fix it, and both matter:
#
#   1. Guard only the register-name block, REG_R8 through REG_CSGSFS. Not
#      every macro whose name begins REG_: REG_SZ is libucontext's own
#      constant, REG_OFFSET is built from it, and guarding those out breaks
#      every architecture rather than fixing one.
#   2. Include <libucontext/libucontext.h> before "defs.h" in the two C files
#      that get the order the wrong way round, so bionic's enum is parsed
#      first.
#
# Only x86_64 is touched. arm and arm64 have no such enum and build untouched.
# ---------------------------------------------------------------------------
patch_x86_64_for_bionic() {
  local defs="" f

  for f in "$SRC_DIR/arch/x86_64/defs.h" "$SRC_DIR/src/arch/x86_64/defs.h"; do
    [ -f "$f" ] && { defs="$f"; break; }
  done

  [ -n "$defs" ] || die "could not find x86_64 defs.h under $SRC_DIR"

  if grep -q "__BIONIC__" "$defs"; then
    echo "    defs.h already guarded"
  else
    python3 - "$defs" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# The contiguous run of register-name defines, and nothing else.
pattern = re.compile(r'(#\s*define\s+REG_R8[\s\S]*?#\s*define\s+REG_CSGSFS[^\n]*\n)', re.M)
match = pattern.search(text)

if not match:
    sys.stderr.write("REG_R8..REG_CSGSFS block not found in %s\n" % path)
    raise SystemExit(1)

block = match.group(1)
text = text[:match.start()] + "#if !defined(__BIONIC__)\n" + block + "#endif\n" + text[match.end():]
path.write_text(text, encoding="utf-8")
PY
    echo "    guarded REG_R8..REG_CSGSFS in ${defs#$SRC_DIR/}"
  fi

  for f in \
    "$SRC_DIR/arch/x86_64/makecontext.c" \
    "$SRC_DIR/arch/x86_64/trampoline.c" \
    "$SRC_DIR/src/arch/x86_64/makecontext.c" \
    "$SRC_DIR/src/arch/x86_64/trampoline.c"
  do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

swapped = re.sub(
    r'^\s*#\s*include\s+"defs\.h"\s*\n\s*#\s*include\s+<libucontext/libucontext\.h>\s*\n',
    '#include <libucontext/libucontext.h>\n#include "defs.h"\n',
    text,
    count=1,
    flags=re.M,
)

if swapped != text:
    path.write_text(swapped, encoding="utf-8")
    print("    reordered includes in %s" % path.name)
PY
  done
}

build_abi() {
  local abi="$1" triple="$2" cpu_family="$3" cpu="$4"
  local out="$PREFIX/$abi"
  local build="$WORK_DIR/build-$abi"
  local cc="$TOOLCHAIN/bin/${triple}${API}-clang"
  local ar="$TOOLCHAIN/bin/llvm-ar"
  local strip="$TOOLCHAIN/bin/llvm-strip"

  [ -x "$cc" ] || die "no compiler for $abi at API $API: $cc"

  log "Building libucontext for $abi (API $API)"

  local cross="$WORK_DIR/cross-$abi.ini"
  cat > "$cross" <<EOF
[binaries]
c = '$cc'
ar = '$ar'
strip = '$strip'
pkgconfig = 'false'

[host_machine]
system = 'android'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'
EOF

  rm -rf "$build"
  meson setup "$build" "$SRC_DIR" \
    --cross-file "$cross" \
    --default-library=static \
    --buildtype=release \
    --prefix "$out"

  # Build the library targets only. A plain `meson compile` would also build
  # the test programs, which link against the host and fail.
  local targets
  targets="$(meson introspect --targets "$build" 2>/dev/null \
    | python3 -c '
import json
import sys

try:
    targets = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

names = []

for t in targets:
    if "static library" not in str(t.get("type", "")).lower():
        continue
    filenames = t.get("filename", [])
    if not isinstance(filenames, list):
        filenames = [filenames]
    haystack = (str(t.get("name", "")) + " " + " ".join(str(f) for f in filenames)).lower()
    if "ucontext" in haystack:
        names.append(str(t.get("name", "")))

print("\n".join(dict.fromkeys(names)))
' || true)"

  if [ -n "$targets" ]; then
    echo "    targets: $(printf '%s ' $targets)"
    local t
    for t in $targets; do
      meson compile -C "$build" -j "$JOBS" "$t"
    done
  else
    echo "    no static ucontext target reported; building everything"
    meson compile -C "$build" -j "$JOBS"
  fi

  local lib=""
  local name
  for name in libucontext.a libucontext_posix.a; do
    lib="$(find "$build" -name "$name" -print -quit 2>/dev/null || true)"
    [ -n "$lib" ] && break
  done

  [ -n "$lib" ] || die "$abi: no libucontext.a was produced under $build"

  rm -rf "$out"
  mkdir -p "$out/lib" "$out/include"
  cp -f "$lib" "$out/lib/libucontext.a"

  if [ -d "$SRC_DIR/include" ]; then
    cp -a "$SRC_DIR/include/." "$out/include/"
  fi

  verify_abi "$abi" "$out/lib/libucontext.a"
}

# The four functions bionic is missing have to be in there under their
# ordinary names, because that is what the fibre dispatcher calls.
#
# Any defined symbol type counts. libucontext publishes the unprefixed names
# as weak aliases of its own libucontext_* symbols, so nm reports them as 'W'
# rather than 'T'. Only 'U' - undefined - disqualifies.
verify_abi() {
  local abi="$1" lib="$2" syms want

  syms="$("$TOOLCHAIN/bin/llvm-nm" "$lib" 2>/dev/null || true)"
  [ -n "$syms" ] || die "$abi: llvm-nm produced no output for $lib"

  for want in getcontext setcontext makecontext swapcontext; do
    if ! printf '%s\n' "$syms" \
        | awk -v s="$want" '
            $NF == s || $NF == "_" s {
              if ($(NF-1) != "U" && $(NF-1) != "u") { found = 1 }
            }
            END { exit !found }'; then
      echo "  symbols matching $want:" >&2
      printf '%s\n' "$syms" | grep -E "$want" >&2 || echo "    (none at all)" >&2
      die "$abi: libucontext.a does not define $want under its unprefixed name"
    fi
  done

  echo "    $lib"
  echo "    defines getcontext, setcontext, makecontext, swapcontext"
}

main() {
  local selected
  mapfile -t selected < <(select_abis "$@")

  echo "libucontext ($LIBUCONTEXT_REF) for Android API $API"
  echo "  NDK:    $NDK"
  echo "  prefix: $PREFIX"
  echo "  ABIs:   $(printf '%s ' "${selected[@]%%:*}")"

  fetch_source

  local entry abi triple cpu_family cpu needs_x86_patch=0
  for entry in "${selected[@]}"; do
    case "${entry%%:*}" in
      x86_64|x86) needs_x86_patch=1 ;;
    esac
  done

  if [ "$needs_x86_patch" = "1" ]; then
    log "Patching x86_64 sources for bionic"
    patch_x86_64_for_bionic
  fi

  for entry in "${selected[@]}"; do
    abi="${entry%%:*}"
    triple="$(printf '%s' "$entry" | cut -d: -f2)"
    cpu_family="$(printf '%s' "$entry" | cut -d: -f3)"
    cpu="$(printf '%s' "$entry" | cut -d: -f4)"
    build_abi "$abi" "$triple" "$cpu_family" "$cpu"
  done

  log "Done. Configure a wallet build for one ABI with:"
  echo "  -D DEROGOLD_ANDROID_PROFILE=ON -D LIBUCONTEXT_ROOT=$PREFIX/<abi>"
}

main "$@"
