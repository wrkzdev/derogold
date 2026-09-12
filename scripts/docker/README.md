# Docker release builds

One command builds the portable DeroGold CLI set for each supported platform
and packs it for release, with the root `LICENSE` inside:

| Target    | Package                                        | How it is built                            |
|-----------|------------------------------------------------|--------------------------------------------|
| `linux`   | `derogold-cli-linux-x86_64-<version>.tar.gz`   | native GCC, fully static binaries          |
| `windows` | `derogold-cli-windows-x86_64-<version>.zip`    | MinGW-w64 (posix threads) + static OpenSSL |

`all` builds both. `<version>` is `MAJOR.MINOR.REV.BUILD` from the
`project(DeroGold VERSION ...)` line in the root `CMakeLists.txt`; override it
with `VERSION=`.

Every package contains, flat inside a directory of the same name:

```
DeroGoldd  degwallet  DeroGold-service  wallet-api  degwallet-upgrader
miner      cryptotest  DeroGold-txpow-server  LICENSE
```

The executable list is taken from the checked-out `src/CMakeLists.txt`, so a
branch that does not build `DeroGold-txpow-server` yet gets a package without
it (the build log notes the omission). A declared executable that is missing
after the build fails the run. A `SHA256SUMS-<version>.txt` is written next to
the packages.

This is a different thing from the two Dockerfiles at the repository root:
`Dockerfile` builds the published container image, and `Dockerfile.portable`
builds one Linux package against an older glibc. This image builds the release
set for several operating systems from one command, and keeps its build trees
and ccache between runs.

## Requirements

- Docker 20.10 or newer (or Podman: `DOCKER=podman`). Any Linux host works;
  Docker Desktop on macOS/Windows works too, the image is always `linux/amd64`.
- About 3 GB of free disk for the image and another 4-6 GB for the build trees.
- RAM: the RocksDB and C++20 sources need roughly 1.5 GB per compile job. A
  4 GB machine should use `JOBS=2`.
- Network access the first time, to fetch the base image, CMake and OpenSSL.
  Later runs are offline.

## Usage

From the repository root:

```bash
# Both targets
bash scripts/docker/build.sh

# One target
bash scripts/docker/build.sh linux
bash scripts/docker/build.sh windows

# Fewer compile jobs on a small machine
JOBS=2 bash scripts/docker/build.sh
```

The first run builds the toolchain image (10-20 minutes, mostly the OpenSSL
compile). After that the image is cached and each run goes straight to the
build. The build trees under `build-docker/` and the ccache inside it survive
between runs, so a rebuild after a small source change is quick; `CLEAN=1`
starts the affected targets from scratch.

Packages land in `builds/`:

```
builds/
  derogold-cli-linux-x86_64-1.0.1.0.tar.gz
  derogold-cli-windows-x86_64-1.0.1.0.zip
  SHA256SUMS-1.0.1.0.txt
```

Per-target logs are in `build-docker/logs/`.

### Options

All options are environment variables. Targets are positional arguments.

| Variable           | Default                        | Meaning                                                        |
|--------------------|--------------------------------|----------------------------------------------------------------|
| `JOBS`             | all CPUs in the container      | parallel compile jobs                                          |
| `VERSION`          | `project()` in `CMakeLists.txt`| version string in the package names                            |
| `OUT_DIR`          | `builds/`                      | where packages and checksums go                                |
| `BUILD_ROOT`       | `build-docker/`                | build trees, staging directories, ccache and logs              |
| `CLEAN`            | `0`                            | `1` wipes each requested target's build tree before configuring|
| `KEEP_GOING`       | `0`                            | `1` keeps building the remaining targets after one fails       |
| `IMAGE`            | `derogold-builder:latest`      | image name                                                     |
| `NO_IMAGE_BUILD`   | `0`                            | `1` skips the `docker build` step                              |
| `IMAGE_BUILD_ARGS` | empty                          | extra `docker build` arguments, see [Toolchain versions](#toolchain-versions) |
| `DOCKER`           | `docker`                       | container CLI                                                  |
| `DOCKER_PLATFORM`  | `linux/amd64`                  | image platform                                                 |

Flags:

- `--shell` opens an interactive shell in the image with the repository at
  `/work`, the build trees at `/build` and the package directory at `/out`.
  Inside it, `bash /work/scripts/docker/container-build.sh linux` does exactly
  what `build.sh linux` does.
- `--image-only` builds or refreshes the image and stops.

On Linux the container runs as your user (under `sudo`, as the user who ran
`sudo`), so nothing in `build-docker/` or `builds/` ends up root-owned.

## What each target does

The flags mirror the manual flows in [BUILDING.md](../../BUILDING.md); the
image just supplies the toolchains.

**Linux** configures with `-D ARCH=default -D SET_COMMIT_ID_IN_VERSION=OFF
-D OPENSSL_USE_STATIC_LIBS=ON -D CMAKE_EXE_LINKER_FLAGS=-static`, then checks
every executable with `file` for `statically linked` before running
`DeroGoldd --version` and `degwallet --version`. `ARCH=default` answers "which
CPUs does this run on" and the static link answers "which machines does it
load on" — together they remove the glibc floor described in BUILDING.md, so
the package runs on distributions far older than the image. The glibc NSS
caveat applies: name lookups use the `files` and `dns` backends built into
glibc, which is what every mainstream distribution ships.

**Windows** uses `CMake/windows-x64-mingw-cross.cmake` with the OpenSSL the
image built for the target (`no-shared`), strips the executables with the
MinGW `strip`, then reads the import tables with `objdump`. This tree already
links MinGW builds with `-static`, so the expected result is that no
`lib*.dll` is imported at all and nothing needs bundling; if that ever
changes, the missing DLLs are copied in and a DLL that cannot be found fails
the build rather than producing a zip that will not start.

## Toolchain versions

Everything the image downloads is pinned at the top of the
[Dockerfile](Dockerfile) and can be changed with `--build-arg`:

| Build argument    | Default | Used for                                              |
|-------------------|---------|-------------------------------------------------------|
| `UBUNTU_VERSION`  | `22.04` | base image: GCC 11, MinGW-w64 GCC, and the build tools |
| `OPENSSL_VERSION` | `3.5.8` | Windows-target OpenSSL (the Linux target uses `libssl-dev`) |

```bash
IMAGE_BUILD_ARGS="--build-arg UBUNTU_VERSION=24.04" \
  bash scripts/docker/build.sh --image-only
```

22.04 is deliberate: it is what the published releases use, and its GCC clears
the floor the bundled RocksDB needs (C++20 `using enum`, GCC 11+).

## Other platforms

WrkzCoin's equivalent image also builds Android and macOS packages. Neither is
possible from this tree yet, and the blockers are in the source rather than in
the image:

- **Android.** bionic has no `getcontext`/`swapcontext`/`makecontext`, which
  the fibre dispatcher in `src/platform/linux/system/` needs, so an Android
  build needs a `libucontext` built per ABI and linked in. It also needs a
  build option to compile without OpenSSL, since the NDK ships none. Both
  exist in WrkzCoin (`WRKZ_ANDROID_DISABLE_OPENSSL`, `LIBUCONTEXT_ROOT`) and
  neither exists here.
- **macOS.** Cross-building needs an osxcross toolchain and an Apple SDK the
  operator supplies, plus a `CMake/` toolchain file for it. There is an
  `osx-x64-clang` preset for building *on* a Mac, which is unaffected.

## Cleaning up

```bash
rm -rf build-docker builds      # build trees, ccache, logs, packages
docker rmi derogold-builder     # the image
```

## Troubleshooting

- **Compiler killed / `c++: fatal error: Killed signal`**: out of memory.
  Lower `JOBS`, or give Docker Desktop more memory.
- **`... is imported by the Windows executables but was not found`**: a MinGW
  runtime DLL the toolchain links against is missing from the image. Report
  the DLL name; the lookup lives in `find_mingw_dll` in `container-build.sh`.
- **`is not statically linked`** from the Linux target: something pulled in a
  library with no static half. `ldd` the binary in `build-docker/linux-x86_64/src`
  to see which.
- **Stale configuration after switching branches**: `CLEAN=1`.
- **Windows host, Git Bash**: `build.sh` converts paths for Docker Desktop
  itself. Check the repository out with LF line endings for the scripts under
  `scripts/docker/`.
