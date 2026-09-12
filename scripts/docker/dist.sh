#!/usr/bin/env bash
#
# Cross-build every platform this tree supports and pack the result into dist/.
#
#   bash scripts/docker/dist.sh                 # everything, into dist/
#   bash scripts/docker/dist.sh linux windows   # a subset, still into dist/
#   JOBS=4 CLEAN=1 bash scripts/docker/dist.sh  # options pass straight through
#
# This is scripts/docker/build.sh with OUT_DIR pointed at dist/ and every
# target selected, which is the combination a release needs:
#
#   dist/derogold-cli-linux-x86_64-<version>.tar.gz     daemon + CLI wallet
#   dist/derogold-cli-linux-arm64-<version>.tar.gz      daemon + CLI wallet
#   dist/derogold-cli-windows-x86_64-<version>.zip      daemon + CLI wallet
#   dist/derogold-gui-linux-x86_64-<version>.tar.gz     DeroGold GUI Wallet
#   dist/derogold-web-wallet-<version>.tar.gz           DeroGold Web Wallet
#   dist/derogold-android-<version>.tar.gz              APK + AAB, release and debug
#   dist/SHA256SUMS-<version>.txt
#
# Subsets, when the whole set is more than you want:
#
#   bash scripts/docker/dist.sh cli     # the three command line packages
#   bash scripts/docker/dist.sh apps    # gui, web and android
#
# macOS is not built: this image has no macOS cross-toolchain, and Apple's SDK
# cannot be redistributed in one. See "Other platforms" in
# scripts/docker/README.md.
#
# Every environment variable build.sh understands works here too - JOBS,
# VERSION, CLEAN, KEEP_GOING, IMAGE, DOCKER and the rest - because this script
# only sets OUT_DIR and then hands over.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Respect an OUT_DIR the caller set on purpose; default to dist/.
export OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"

# KEEP_GOING by default: one toolchain failing should still leave you with the
# packages that did build, rather than nothing. build.sh still exits non-zero
# at the end, so a release script can tell.
export KEEP_GOING="${KEEP_GOING:-1}"

echo "==> Packing into $OUT_DIR"

exec bash "$SCRIPT_DIR/build.sh" "${@:-all}"
